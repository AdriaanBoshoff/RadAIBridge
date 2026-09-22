unit RadAiBridge.Tools.Design;

{ Live UI designer access - framework agnostic (works for FMX and VCL forms
  alike, since both go through IDesigner / TComponent + RTTI). Lets an AI
  agent read the component tree of the form currently open in the Designer
  and add/remove components or get/set any published property, without
  hand-editing .fmx/.dfm text. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Rtti, System.TypInfo,
  ToolsAPI, DesignIntf, RadAiBridge.Rtti.Utils;

procedure RegisterDesignTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);

implementation

function TryGetModuleDesigner(Module: IOTAModule; out Designer: IDesigner): Boolean;
var
  Editor: IOTAEditor;
  FormEditor: IOTAFormEditor;
  NTAFormEditor: INTAFormEditor;
  i: Integer;
begin
  Result := False;
  if Module = nil then
    Exit;
  for i := 0 to Module.GetModuleFileCount - 1 do
  begin
    Editor := Module.GetModuleFileEditor(i);
    if not Supports(Editor, IOTAFormEditor, FormEditor) then
      Continue;
    { IOTAFormEditor does not implement IDesigner directly - the designer is
      reached via the sibling INTAFormEditor interface's GetFormDesigner. }
    if Supports(FormEditor, INTAFormEditor, NTAFormEditor) then
    begin
      Designer := NTAFormEditor.GetFormDesigner;
      if Designer <> nil then
        Exit(True);
    end;
  end;
end;

function GetCurrentDesigner: IDesigner;
var
  ModuleServices: IOTAModuleServices;
  i: Integer;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAModuleServices, ModuleServices) then
    Exit;

  { Prefer the nominally "current" module, but IDE focus tracking can lag or
    point elsewhere depending on which tab/panel last had focus, so fall back
    to scanning every open module for one with a live form designer. }
  if TryGetModuleDesigner(ModuleServices.CurrentModule, Result) then
    Exit;

  for i := 0 to ModuleServices.ModuleCount - 1 do
    if TryGetModuleDesigner(ModuleServices.Modules[i], Result) then
      Exit;
end;

function FindComponentByName(Root: TComponent; const Name: string): TComponent;
var
  i: Integer;
begin
  Result := nil;
  if Root = nil then
    Exit;
  if SameText(Root.Name, Name) then
    Exit(Root);
  for i := 0 to Root.ComponentCount - 1 do
  begin
    Result := FindComponentByName(Root.Components[i], Name);
    if Result <> nil then
      Exit;
  end;
end;

{ The handful of properties that actually describe a form's layout. A full
  property dump of even a small form runs to thousands of lines, which is
  unusable as a mental model - callers who need everything ask for a single
  component with getComponentProperties instead. }
const
  LayoutProperties: array[0..10] of string = (
    'Align', 'Anchors', 'Text', 'Caption', 'Visible', 'Enabled',
    'Position.X', 'Position.Y', 'Size.Width', 'Size.Height', 'TabOrder');

function PropsToJson(Comp: TComponent; AllProperties: Boolean): TJSONObject;
var
  Ctx: TRttiContext;
  Prop: TRttiProperty;
  Owner: TObject;
  Props: TJSONObject;
  Path, S: string;
begin
  Props := TJSONObject.Create;
  Ctx := TRttiContext.Create;
  try
    if AllProperties then
    begin
      for Prop in Ctx.GetType(Comp.ClassType).GetProperties do
      begin
        if not (Prop.Visibility in [mvPublic, mvPublished]) then
          Continue;
        if ReadPropertyAsString(Comp, Prop, S) then
          Props.AddPair(Prop.Name, S);
      end;
    end
    else
      for Path in LayoutProperties do
        if ResolvePropertyPath(Ctx, Comp, Path, Owner, Prop) then
          if ReadPropertyAsString(Owner, Prop, S) then
            Props.AddPair(Path, S);
  finally
    Ctx.Free;
  end;
  Result := Props;
end;

{ Reads a component's visual parent through RTTI rather than typing against
  TControl or TFmxObject, which keeps this unit free of any framework
  dependency while working identically for VCL and FMX. }
function GetVisualParent(var Ctx: TRttiContext; Comp: TComponent): TComponent;
var
  Prop: TRttiProperty;
  Obj: TObject;
begin
  Result := nil;
  Prop := Ctx.GetType(Comp.ClassType).GetProperty('Parent');
  if (Prop = nil) or not Prop.IsReadable or
     (Prop.PropertyType.TypeKind <> tkClass) then
    Exit;
  Obj := Prop.GetValue(Comp).AsObject;
  if Obj is TComponent then
    Result := TComponent(Obj);
end;

function ComponentToJson(var Ctx: TRttiContext; Comp, Root: TComponent;
  AllProperties: Boolean): TJSONObject;
var
  Obj: TJSONObject;
  Children: TJSONArray;
  Child: TComponent;
  i: Integer;
begin
  Obj := TJSONObject.Create;
  Obj.AddPair('name', Comp.Name);
  Obj.AddPair('className', Comp.ClassName);
  Obj.AddPair('properties', PropsToJson(Comp, AllProperties));

  { Every component on a form is owned flat by the form, so nesting has to come
    from the Parent chain - otherwise a toolbar's buttons appear as siblings of
    the toolbar, which misrepresents the layout. Non-visual components have no
    Parent and are collected under the root. }
  Children := TJSONArray.Create;
  for i := 0 to Root.ComponentCount - 1 do
  begin
    Child := Root.Components[i];
    if Child = Comp then
      Continue;
    if GetVisualParent(Ctx, Child) = Comp then
      Children.Add(ComponentToJson(Ctx, Child, Root, AllProperties))
    else if (Comp = Root) and (GetVisualParent(Ctx, Child) = nil) then
      Children.Add(ComponentToJson(Ctx, Child, Root, AllProperties));
  end;
  Obj.AddPair('children', Children);
  Result := Obj;
end;

function ToolGetFormTree(Params: TJSONObject): TJSONValue;
var
  Designer: IDesigner;
  Ctx: TRttiContext;
begin
  Designer := GetCurrentDesigner;
  if Designer = nil then
    raise Exception.Create('No form is currently open in the Designer');
  Ctx := TRttiContext.Create;
  try
    Result := ComponentToJson(Ctx, Designer.Root, Designer.Root,
      Params.GetValue<Boolean>('allProperties', False));
  finally
    Ctx.Free;
  end;
end;

function ToolGetComponentProperties(Params: TJSONObject): TJSONValue;
var
  Designer: IDesigner;
  Comp: TComponent;
  CompName: string;
begin
  Designer := GetCurrentDesigner;
  if Designer = nil then
    raise Exception.Create('No form is currently open in the Designer');
  CompName := Params.GetValue<string>('componentName');
  Comp := FindComponentByName(Designer.Root, CompName);
  if Comp = nil then
    raise Exception.CreateFmt('Component not found: %s', [CompName]);
  Result := PropsToJson(Comp, True);
end;

{ Applies one "Path=Value" assignment to Comp. Shared by the single and batch
  property tools so both accept exactly the same path and value syntax. }
procedure ApplyPropertyPath(var Ctx: TRttiContext; Comp: TComponent;
  const Path, Value: string);
var
  Owner: TObject;
  Prop: TRttiProperty;
begin
  if not ResolvePropertyPath(Ctx, Comp, Path, Owner, Prop) then
    raise Exception.CreateFmt('Property not found: %s.%s', [Comp.Name, Path]);
  SetPropertyFromString(Owner, Prop, Comp.Name + '.' + Path, Value);
end;

function ToolSetComponentProperty(Params: TJSONObject): TJSONValue;
var
  Designer: IDesigner;
  Comp: TComponent;
  CompName: string;
  Ctx: TRttiContext;
begin
  Designer := GetCurrentDesigner;
  if Designer = nil then
    raise Exception.Create('No form is currently open in the Designer');
  CompName := Params.GetValue<string>('componentName');
  Comp := FindComponentByName(Designer.Root, CompName);
  if Comp = nil then
    raise Exception.CreateFmt('Component not found: %s', [CompName]);

  Ctx := TRttiContext.Create;
  try
    ApplyPropertyPath(Ctx, Comp, Params.GetValue<string>('propertyName'),
      Params.GetValue<string>('value'));
  finally
    Ctx.Free;
  end;

  Designer.Modified;
  Result := TJSONBool.Create(True);
end;

{ Laying out a form means setting dozens of properties. One round trip per
  property is the single biggest source of latency in building a UI, so this
  takes a whole "Comp.Path" -> "Value" map at once. It is deliberately
  all-or-nothing in reporting terms: every failure is collected and returned
  rather than aborting, because a half-applied layout is easier to repair when
  you can see exactly which assignments didn't take. }
function ToolSetComponentProperties(Params: TJSONObject): TJSONValue;
var
  Designer: IDesigner;
  Comp: TComponent;
  Assignments: TJSONObject;
  Pair: TJSONPair;
  Ctx: TRttiContext;
  Key, CompName, Path: string;
  DefaultComp: string;
  DotPos: Integer;
  Failures: TJSONArray;
  Failure: TJSONObject;
  Applied: Integer;
  Obj: TJSONObject;
begin
  Designer := GetCurrentDesigner;
  if Designer = nil then
    raise Exception.Create('No form is currently open in the Designer');

  if not (Params.GetValue('properties') is TJSONObject) then
    raise Exception.Create('"properties" must be an object of path/value pairs');
  Assignments := Params.GetValue('properties') as TJSONObject;
  DefaultComp := Params.GetValue<string>('componentName', '');

  Failures := TJSONArray.Create;
  Applied := 0;
  Ctx := TRttiContext.Create;
  try
    for Pair in Assignments do
    begin
      Key := Pair.JsonString.Value;
      { With componentName given, keys are plain property paths on it.
        Without, the first segment names the component, so a single call can
        span the whole form: "AddBtn.Text" -> "+", "ListBox1.Align" -> "Client". }
      if DefaultComp <> '' then
      begin
        CompName := DefaultComp;
        Path := Key;
      end
      else
      begin
        DotPos := Pos('.', Key);
        if DotPos <= 1 then
        begin
          Failure := TJSONObject.Create;
          Failure.AddPair('path', Key);
          Failure.AddPair('error', 'Without "componentName", each key must be ' +
            '"ComponentName.PropertyPath"');
          Failures.Add(Failure);
          Continue;
        end;
        CompName := Copy(Key, 1, DotPos - 1);
        Path := Copy(Key, DotPos + 1, MaxInt);
      end;

      try
        Comp := FindComponentByName(Designer.Root, CompName);
        if Comp = nil then
          raise Exception.CreateFmt('Component not found: %s', [CompName]);
        ApplyPropertyPath(Ctx, Comp, Path, Pair.JsonValue.Value);
        Inc(Applied);
      except
        on E: Exception do
        begin
          Failure := TJSONObject.Create;
          Failure.AddPair('path', Key);
          Failure.AddPair('error', E.Message);
          Failures.Add(Failure);
        end;
      end;
    end;
  finally
    Ctx.Free;
  end;

  Designer.Modified;
  Obj := TJSONObject.Create;
  Obj.AddPair('applied', TJSONNumber.Create(Applied));
  Obj.AddPair('failed', TJSONNumber.Create(Failures.Count));
  Obj.AddPair('failures', Failures);
  Result := Obj;
end;

function ToolSetComponentEvent(Params: TJSONObject): TJSONValue;
var
  Designer: IDesigner;
  Comp: TComponent;
  CompName, EventName, MethodName: string;
  Ctx: TRttiContext;
  Prop: TRttiProperty;
  M: TMethod;
  V: TValue;
begin
  Designer := GetCurrentDesigner;
  if Designer = nil then
    raise Exception.Create('No form is currently open in the Designer');
  CompName := Params.GetValue<string>('componentName');
  EventName := Params.GetValue<string>('eventName');
  MethodName := Params.GetValue<string>('methodName');
  Comp := FindComponentByName(Designer.Root, CompName);
  if Comp = nil then
    raise Exception.CreateFmt('Component not found: %s', [CompName]);

  Ctx := TRttiContext.Create;
  try
    Prop := Ctx.GetType(Comp.ClassType).GetProperty(EventName);
    if Prop = nil then
      raise Exception.CreateFmt('Event not found: %s.%s', [CompName, EventName]);
    if Prop.PropertyType.TypeKind <> tkMethod then
      raise Exception.CreateFmt('%s.%s is not an event property', [CompName, EventName]);

    { CreateMethod binds to an existing method of matching signature in the unit,
      or - like typing a new name into the Object Inspector's Events tab - generates
      a skeleton for it if it doesn't exist yet. }
    M := Designer.CreateMethod(MethodName, GetTypeData(Prop.PropertyType.Handle));

    { TValue.Make against the property's own type info, not TValue.From<TMethod>:
      the latter carries generic TMethod type info that won't cast to the
      specific event type (TNotifyEvent etc.) and raises EInvalidCast. }
    TValue.Make(@M, Prop.PropertyType.Handle, V);
    Prop.SetValue(Comp, V);
  finally
    Ctx.Free;
  end;

  Designer.Modified;
  Result := TJSONBool.Create(True);
end;

{ Selecting is what makes the work visible: the components show handles in the
  designer and the Object Inspector follows, so the user can see and check what
  was just built instead of taking the tool's word for it. }
function ToolSelectComponent(Params: TJSONObject): TJSONValue;
var
  Designer: IDesigner;
  Comp: TComponent;
  Selections: IDesignerSelections;
  Names: TArray<string>;
  NameList: TJSONArray;
  CompName: string;
  i: Integer;
  Arr: TJSONArray;
begin
  Designer := GetCurrentDesigner;
  if Designer = nil then
    raise Exception.Create('No form is currently open in the Designer');

  if Params.GetValue('componentNames') is TJSONArray then
  begin
    NameList := Params.GetValue('componentNames') as TJSONArray;
    SetLength(Names, NameList.Count);
    for i := 0 to NameList.Count - 1 do
      Names[i] := NameList.Items[i].Value;
  end
  else
    Names := [Params.GetValue<string>('componentName')];

  Selections := CreateSelectionList;
  Arr := TJSONArray.Create;
  for CompName in Names do
  begin
    Comp := FindComponentByName(Designer.Root, CompName);
    if Comp = nil then
      raise Exception.CreateFmt('Component not found: %s', [CompName]);
    Selections.Add(Comp);
    Arr.Add(Comp.Name);
  end;

  { An empty list would clear the selection rather than select the form, so the
    root is selected explicitly when nothing was named. }
  if Selections.Count = 0 then
    Designer.SelectComponent(Designer.Root)
  else
    Designer.SetSelections(Selections);

  Result := Arr;
end;

function ToolAddComponent(Params: TJSONObject): TJSONValue;
var
  Designer: IDesigner;
  Parent, NewComp: TComponent;
  ParentName, ClassNameStr, DesiredName: string;
  Left, Top, Width, Height: Integer;
  CompClass: TComponentClass;
  PersistentClass: TPersistentClass;
  Ctx: TRttiContext;
begin
  Designer := GetCurrentDesigner;
  if Designer = nil then
    raise Exception.Create('No form is currently open in the Designer');

  ClassNameStr := Params.GetValue<string>('className');
  ParentName := Params.GetValue<string>('parentName', '');
  Left := Params.GetValue<Integer>('left', 0);
  Top := Params.GetValue<Integer>('top', 0);
  Width := Params.GetValue<Integer>('width', 100);
  Height := Params.GetValue<Integer>('height', 25);

  if ParentName <> '' then
    Parent := FindComponentByName(Designer.Root, ParentName)
  else
    Parent := Designer.Root;
  if Parent = nil then
    raise Exception.CreateFmt('Parent component not found: %s', [ParentName]);

  PersistentClass := GetClass(ClassNameStr);
  if (PersistentClass = nil) or not PersistentClass.InheritsFrom(TComponent) then
    raise Exception.CreateFmt('Unknown or unregistered component class: %s. ' +
      'It must already be registered with the IDE (e.g. used elsewhere in the project, ' +
      'or its unit added to the form''s uses clause and the package installed).', [ClassNameStr]);
  CompClass := TComponentClass(PersistentClass);

  NewComp := Designer.CreateComponent(CompClass, Parent, Left, Top, Width, Height);
  if NewComp = nil then
    raise Exception.Create('Designer failed to create the component');

  { Naming up front beats accepting Button1/Memo1 and renaming later: the name
    is what every other tool addresses the component by, it's what ends up in
    the generated event handler names, and IDE add-ins that offer to rename
    default-named components on save have nothing to ask about. }
  DesiredName := Params.GetValue<string>('name', '');
  if DesiredName <> '' then
  begin
    if not IsValidIdent(DesiredName) then
      raise Exception.CreateFmt('"%s" is not a valid component name', [DesiredName]);
    if FindComponentByName(Designer.Root, DesiredName) <> nil then
      raise Exception.CreateFmt('A component named "%s" already exists on this form',
        [DesiredName]);
    NewComp.Name := DesiredName;
  end;

  Designer.Modified;
  Ctx := TRttiContext.Create;
  try
    Result := ComponentToJson(Ctx, NewComp, Designer.Root, False);
  finally
    Ctx.Free;
  end;
end;

function ToolDeleteComponent(Params: TJSONObject): TJSONValue;
var
  Designer: IDesigner;
  Comp: TComponent;
  CompName: string;
begin
  Designer := GetCurrentDesigner;
  if Designer = nil then
    raise Exception.Create('No form is currently open in the Designer');
  CompName := Params.GetValue<string>('componentName');
  Comp := FindComponentByName(Designer.Root, CompName);
  if Comp = nil then
    raise Exception.CreateFmt('Component not found: %s', [CompName]);
  if Comp = Designer.Root then
    raise Exception.Create('Cannot delete the root form/frame component');

  Comp.Free;
  Designer.Modified;
  Result := TJSONBool.Create(True);
end;

procedure RegisterDesignTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);
var
  F: TFunc<TJSONObject, TJSONValue>;
begin
  F := ToolGetFormTree;             RegisterFn('getFormTree', F);
  F := ToolGetComponentProperties;  RegisterFn('getComponentProperties', F);
  F := ToolSetComponentProperty;    RegisterFn('setComponentProperty', F);
  F := ToolSetComponentProperties;  RegisterFn('setComponentProperties', F);
  F := ToolSetComponentEvent;       RegisterFn('setComponentEvent', F);
  F := ToolSelectComponent;         RegisterFn('selectComponent', F);
  F := ToolAddComponent;            RegisterFn('addComponent', F);
  F := ToolDeleteComponent;         RegisterFn('deleteComponent', F);
end;

end.
