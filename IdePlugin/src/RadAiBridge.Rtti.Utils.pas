unit RadAiBridge.Rtti.Utils;

{ Shared RTTI plumbing for the design-time tools: resolving dotted property
  paths ("TextSettings.Font.Size") down to the object that owns the leaf, and
  coercing strings into whatever the property's type actually is.

  This lives apart from the tool handlers because the coercion rules are the
  fiddly part and every caller needs them to behave identically - the single
  property setter, the batch setter, and the component creator all funnel
  through here. }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo;

{ Walks a dotted path from Instance. On success Owner is the object that holds
  the final property and Prop is that property; a single-segment path just
  yields Instance itself. }
function ResolvePropertyPath(var Ctx: TRttiContext; Instance: TObject;
  const Path: string; out Owner: TObject; out Prop: TRttiProperty): Boolean;

{ Assigns S to Prop on Instance, converting per the property's type kind.
  Raises with a message naming Path when the value doesn't fit. }
procedure SetPropertyFromString(Instance: TObject; Prop: TRttiProperty;
  const Path, S: string);

{ Renders a property as text the way the Object Inspector would. Returns False
  for kinds that have no sensible flat representation (interfaces, methods,
  most sub-objects) so callers can simply skip them. }
function ReadPropertyAsString(Instance: TObject; Prop: TRttiProperty;
  out S: string): Boolean;

implementation

function EnumValueNames(TypeInf: PTypeInfo): string;
var
  Data: PTypeData;
  i: Integer;
begin
  Result := '';
  Data := GetTypeData(TypeInf);
  for i := Data.MinValue to Data.MaxValue do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + GetEnumName(TypeInf, i);
  end;
end;

function NormalizeSetLiteral(const S: string): string;
begin
  Result := Trim(S);
  if Result = '' then
    Result := '[]'
  else if Result[1] <> '[' then
    Result := '[' + Result + ']';
end;

{ Named constants such as clRed or claWhite are registered by the graphics
  units via RegisterIntegerConsts. Going through FindIdentToInt gives us the
  exact same lookup the .dfm/.fmx streamer and the Object Inspector use, so we
  inherit VCL and FMX colour names without linking either framework in. }
function TryStrToOrdinalValue(TypeInf: PTypeInfo; const S: string;
  out V: Int64): Boolean;
var
  Ident: TIdentToInt;
  I: Integer;
begin
  if TryStrToInt64(S, V) then
    Exit(True);
  Result := False;
  Ident := FindIdentToInt(TypeInf);
  if Assigned(Ident) and Ident(S, I) then
  begin
    { $FFFF0000 reads back as a negative Integer. Re-widen it according to the
      target's signedness or a Cardinal property would fail its range check. }
    if GetTypeData(TypeInf).OrdType in [otUByte, otUWord, otULong] then
      V := Cardinal(I)
    else
      V := I;
    Result := True;
  end;
end;

function ReadSetAsOrdinal(const Val: TValue): Integer;
var
  Size: Integer;
begin
  Result := 0;
  Size := Val.DataSize;
  if Size > SizeOf(Result) then
    Size := SizeOf(Result);
  if Size > 0 then
    Move(Val.GetReferenceToRawData^, Result, Size);
end;

function ResolvePropertyPath(var Ctx: TRttiContext; Instance: TObject;
  const Path: string; out Owner: TObject; out Prop: TRttiProperty): Boolean;
var
  Parts: TArray<string>;
  i: Integer;
  RttiType: TRttiType;
  Current: TRttiProperty;
begin
  Owner := Instance;
  Prop := nil;
  if (Instance = nil) or (Path = '') then
    Exit(False);

  Parts := Path.Split(['.']);
  for i := 0 to High(Parts) do
  begin
    if Owner = nil then
      Exit(False);
    RttiType := Ctx.GetType(Owner.ClassType);
    if RttiType = nil then
      Exit(False);
    Current := RttiType.GetProperty(Parts[i]);
    if Current = nil then
      Exit(False);
    if i = High(Parts) then
    begin
      Prop := Current;
      Exit(True);
    end;
    { Intermediate segments have to be sub-objects (TPosition, TTextSettings,
      TFont...). Both FMX and VCL model these as TPersistent descendants rather
      than records, so a class-kind check covers every real case. }
    if Current.PropertyType.TypeKind <> tkClass then
      Exit(False);
    Owner := Current.GetValue(Owner).AsObject;
  end;
  Result := False;
end;

procedure SetPropertyFromString(Instance: TObject; Prop: TRttiProperty;
  const Path, S: string);

  procedure Fail(const Expected: string);
  begin
    raise Exception.CreateFmt('Cannot assign "%s" to %s: expected %s',
      [S, Path, Expected]);
  end;

var
  Ordinal: Int64;
  Flt: Extended;
  SetBits: Integer;
  Val: TValue;
  Obj: TObject;
begin
  { A TStrings property is read-only by design yet still assignable through the
    object it returns, so the writability gate only applies to value kinds. }
  if not Prop.IsWritable and (Prop.PropertyType.TypeKind <> tkClass) then
    raise Exception.CreateFmt('Property is read-only: %s', [Path]);

  case Prop.PropertyType.TypeKind of
    tkInteger:
      begin
        if not TryStrToOrdinalValue(Prop.PropertyType.Handle, S, Ordinal) then
          Fail('an integer or a registered constant name such as claRed');
        Prop.SetValue(Instance, TValue.FromOrdinal(Prop.PropertyType.Handle, Ordinal));
      end;
    tkInt64:
      begin
        if not TryStrToInt64(S, Ordinal) then
          Fail('a 64-bit integer');
        Prop.SetValue(Instance, TValue.From<Int64>(Ordinal));
      end;
    tkFloat:
      begin
        { Accept both invariant and locale decimal separators - callers write
          JSON-ish "12.5" but the IDE may be running under a comma locale. }
        if not TryStrToFloat(S, Flt, TFormatSettings.Invariant) and
           not TryStrToFloat(S, Flt) then
          Fail('a number');
        Prop.SetValue(Instance, TValue.From<Extended>(Flt));
      end;
    tkEnumeration:
      begin
        if Prop.PropertyType.Handle = TypeInfo(Boolean) then
          Prop.SetValue(Instance, TValue.From<Boolean>(
            SameText(S, 'true') or SameText(S, '1') or SameText(S, 'yes')))
        else
        begin
          Ordinal := GetEnumValue(Prop.PropertyType.Handle, S);
          if Ordinal < 0 then
            Fail('one of: ' + EnumValueNames(Prop.PropertyType.Handle));
          Prop.SetValue(Instance, TValue.FromOrdinal(Prop.PropertyType.Handle, Ordinal));
        end;
      end;
    tkSet:
      begin
        { StringToSet wants the bracketed literal the streamer uses; accept a
          bare comma list too, since that's what a caller naturally writes. }
        try
          SetBits := StringToSet(Prop.PropertyType.Handle, NormalizeSetLiteral(S));
        except
          on E: Exception do
            Fail('a set literal such as [akLeft,akBottom]');
        end;
        TValue.Make(@SetBits, Prop.PropertyType.Handle, Val);
        Prop.SetValue(Instance, Val);
      end;
    tkClass:
      begin
        Obj := Prop.GetValue(Instance).AsObject;
        if Obj is TStrings then
          TStrings(Obj).Text := S
        else
          Fail(Format('a simple value; %s is an object, so set one of its ' +
            'sub-properties instead (e.g. %s.SomeProperty)', [Path, Path]));
      end;
    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      Prop.SetValue(Instance, TValue.From<string>(S));
  else
    Fail('a supported property type (this one is ' +
      GetEnumName(TypeInfo(TTypeKind), Ord(Prop.PropertyType.TypeKind)) + ')');
  end;
end;

function ReadPropertyAsString(Instance: TObject; Prop: TRttiProperty;
  out S: string): Boolean;
var
  Val: TValue;
  ToIdent: TIntToIdent;
  Ident: string;
  Obj: TObject;
begin
  S := '';
  if not Prop.IsReadable then
    Exit(False);
  try
    Val := Prop.GetValue(Instance);
    case Prop.PropertyType.TypeKind of
      tkInteger:
        begin
          { Render colours and other registered constants by name, matching
            what the caller would have to type to set them back. }
          ToIdent := FindIntToIdent(Prop.PropertyType.Handle);
          if Assigned(ToIdent) and ToIdent(Val.AsOrdinal, Ident) then
            S := Ident
          else
            S := Val.ToString;
        end;
      tkSet:
        S := SetToString(Prop.PropertyType.Handle, ReadSetAsOrdinal(Val), True);
      tkClass:
        begin
          Obj := Val.AsObject;
          if Obj is TStrings then
            S := TStrings(Obj).Text
          else
            Exit(False);
        end;
      tkInt64, tkFloat, tkString, tkLString, tkWString, tkUString,
      tkChar, tkWChar, tkEnumeration:
        S := Val.ToString;
    else
      Exit(False);
    end;
    Result := True;
  except
    { Some published properties raise on read at design time (unassigned
      sub-objects, style lookups). Those are skipped, not fatal. }
    Result := False;
  end;
end;

end.
