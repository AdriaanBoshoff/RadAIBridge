import { createConnection, Socket } from "node:net";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

interface Discovery {
  port: number;
  pid: number;
  version: string;
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
}

function discoveryFilePath(): string {
  const appData = process.env.APPDATA;
  if (!appData) {
    throw new Error("APPDATA environment variable is not set - cannot locate the RAD Studio bridge discovery file");
  }
  return join(appData, "RadAiBridge", "bridge.json");
}

function readDiscovery(): Discovery {
  const path = discoveryFilePath();
  if (!existsSync(path)) {
    throw new Error(
      "RAD Studio AI Bridge is not running. Open RAD Studio with the RadAiBridge package installed " +
        `(expected discovery file at ${path}).`
    );
  }
  const raw = readFileSync(path, "utf-8").replace(/^﻿/, "");
  return JSON.parse(raw) as Discovery;
}

export class BridgeClient {
  private socket: Socket | null = null;
  private buffer = "";
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();
  private connectPromise: Promise<void> | null = null;

  private async ensureConnected(): Promise<void> {
    if (this.socket && !this.socket.destroyed) {
      return;
    }
    if (this.connectPromise) {
      return this.connectPromise;
    }
    this.connectPromise = this.connect().finally(() => {
      this.connectPromise = null;
    });
    return this.connectPromise;
  }

  private connect(): Promise<void> {
    const discovery = readDiscovery();
    return new Promise((resolve, reject) => {
      const socket = createConnection({ host: "127.0.0.1", port: discovery.port }, () => {
        this.socket = socket;
        resolve();
      });
      socket.setEncoding("utf-8");
      socket.on("data", (chunk: string) => this.onData(chunk));
      socket.on("error", (err) => {
        this.failAllPending(err);
        reject(err);
      });
      socket.on("close", () => {
        this.socket = null;
        this.failAllPending(new Error("Connection to RAD Studio bridge closed"));
      });
    });
  }

  private onData(chunk: string): void {
    this.buffer += chunk;
    let idx: number;
    while ((idx = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, idx).replace(/\r$/, "");
      this.buffer = this.buffer.slice(idx + 1);
      if (!line.trim()) continue;
      this.handleLine(line);
    }
  }

  private handleLine(line: string): void {
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    const id = msg.id as number;
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    if (msg.error) {
      pending.reject(new Error(msg.error.message ?? "Unknown error from RAD Studio bridge"));
    } else {
      pending.resolve(msg.result);
    }
  }

  private failAllPending(err: Error): void {
    for (const [, p] of this.pending) {
      p.reject(err);
    }
    this.pending.clear();
  }

  async call(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
    await this.ensureConnected();
    if (!this.socket) {
      throw new Error("Not connected to RAD Studio bridge");
    }
    const id = this.nextId++;
    const request = JSON.stringify({ id, method, params }) + "\n";
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket!.write(request, "utf-8", (err) => {
        if (err) {
          this.pending.delete(id);
          reject(err);
        }
      });
    });
  }
}
