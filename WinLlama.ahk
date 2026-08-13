#Requires AutoHotkey v2.0
#SingleInstance Force

Persistent true
OnExit(CleanupOwnedServices)

; ============================================================
;  THEME
; ============================================================

BaseColor      := "1B1E1E"
SecondaryColor := "242929"
RaisedColor    := "2C3232"
SelectedColor  := "344242"

TextColor      := "E6EAEA"
MutedColor     := "AAB3B3"
BorderColor    := "394141"

BaseBrush      := CreateBrush(BaseColor)
SecondaryBrush := CreateBrush(SecondaryColor)
RaisedBrush    := CreateBrush(RaisedColor)
SelectedBrush  := CreateBrush(SelectedColor)
BorderBrush    := CreateBrush(BorderColor)

OnMessage(0x002B, DarkDrawItem)      ; WM_DRAWITEM
OnMessage(0x002C, DarkMeasureItem)   ; WM_MEASUREITEM
OnMessage(0x0134, DarkListBox)       ; WM_CTLCOLORLISTBOX

; ============================================================
;  CONFIGURATION
; ============================================================

ConfigFile := A_ScriptDir "\config.ini"

if !FileExist(ConfigFile) {
    MsgBox(
        "Configuration file not found:`n`n" ConfigFile,
        "Local AI",
        "Iconx"
    )
    ExitApp
}

ModelList := ConfigReadList(
    "General",
    "ModelList"
)

ServerList := ConfigReadList(
    "General",
    "ServerList"
)

LastModel := ConfigRead(
    "State",
    "LastModel",
    ConfigRead(
        "General",
        "LastModel",
        ""
    )
)

; Legacy runtime value until registered llama servers take ownership
; of address/port in the next stages.
LegacyLlamaPort := ConfigReadInteger(
    "General",
    "LlamaPort",
    18080
)

LegacyMcpMode := StrLower(
    Trim(
        ConfigRead(
            "MCP",
            "Mode",
            ""
        )
    )
)

McpEnabled := ConfigReadBoolean(
    "MCP",
    "Enabled",
    true
)

; Remote MCP support existed briefly during development. An old Remote
; configuration must not be reinterpreted as a local bind target.
if LegacyMcpMode != "" {
    if LegacyMcpMode = "remote" {
        McpEnabled := false
        ConfigWrite(
            "MCP",
            "Enabled",
            "false"
        )
    }

    try ConfigDeleteKey(
        "MCP",
        "Mode"
    )
}

McpAddress := ConfigRead(
    "MCP",
    "Address",
    "127.0.0.1"
)

McpPort := ConfigReadInteger(
    "MCP",
    "Port",
    18081,
    1,
    65535
)

McpDirectories := ConfigRead(
    "MCP",
    "GlobalDirectories",
    ConfigRead(
        "MCP",
        "Directories",
        ""
    )
)

LogsDirectory := ResolvePath(
    ConfigRead(
        "General",
        "LogsDirectory",
        "Logs"
    )
)

MigrateLegacyServerConfiguration()

Servers := LoadServers()
Models := LoadModels()

LlamaPid := 0
McpPid := 0

LlamaLog := LogsDirectory "\llama.log"
McpLog := LogsDirectory "\mcp.log"

if !DirExist(LogsDirectory)
    DirCreate(LogsDirectory)

ControllerMode := "start"

ActiveHasLaunched := false

ActiveModelKey := ""
ActiveServerKey := ""
ActiveContext := 0
ActiveCache := ""
ActiveMcpDirectories := ""
ActiveMcpConfig := 0

ActiveConfigDialog := 0

ServerManagerState := 0
ServerEditorState := 0
ModelRegistrationState := 0

ActivePollRate := 0
FastPollRate := 1000
IdlePollRate := 5000

LlamaState := "offline"
McpState := "offline"

LlamaStartupUntil := 0
McpStartupUntil := 0
LlamaStartupGrace := 30000
McpStartupGrace := 15000

; ============================================================
; LOG VIEWER GLOBALS
; ============================================================

ConsoleGui := 0

ConsoleActiveTab := "llama"

ConsoleLlamaPosition := 0
ConsoleMcpPosition := 0

ConsoleLlamaText := ""
ConsoleMcpText := ""

ConsoleEffectiveRate := 250
ConsoleRateCheckInterval := 250

ConsoleWrapEnabled := false

ConsoleMinRate := 100
ConsoleMaxRate := 86400000

DarkButtonFillOverrides := Map()

; --------------- ----------- - -----TEMPORARY MIGRATION STUFF
MigrateLegacyServerConfiguration() {
    global ModelList
    global ServerList
    global LegacyLlamaPort

    ServersByExecutable := Map()
    ServerListChanged := false


    ; --------------------------------------------------------
    ;  INDEX ALREADY-REGISTERED SERVERS
    ; --------------------------------------------------------

    for ServerKey in ServerList {
        Executable :=
            ConfigRead(
                ServerKey,
                "Executable",
                ""
            )

        if Executable = ""
            continue

        ServersByExecutable[
            NormalizeConfigPath(
                Executable
            )
        ] := ServerKey
    }


    ; --------------------------------------------------------
    ;  MIGRATE LEGACY MODEL SERVER PATHS
    ; --------------------------------------------------------

    for ModelKey in ModelList {
        ServerValue :=
            Trim(
                ConfigRead(
                    ModelKey,
                    "Server",
                    ""
                )
            )

        if ServerValue = ""
            continue


        ; Already a registered server key.
        if ListContainsValue(
            ServerList,
            ServerValue
        )
            continue


        ; An unknown non-path value is treated as a dangling
        ; server reference, not something migration should invent.
        if !LooksLikeConfigPath(
            ServerValue
        )
            continue


        ExecutableKey :=
            NormalizeConfigPath(
                ServerValue
            )


        ; ----------------------------------------------------
        ;  REUSE AN EXISTING SERVER FOR THE SAME EXECUTABLE
        ; ----------------------------------------------------

        if ServersByExecutable.Has(
            ExecutableKey
        ) {
            ServerKey :=
                ServersByExecutable[
                    ExecutableKey
                ]
        }


        ; ----------------------------------------------------
        ;  REGISTER A NEW SERVER
        ; ----------------------------------------------------

        else {
            Name :=
                DeriveServerName(
                    ServerValue
                )

            ServerKey :=
                GenerateConfigKey(
                    Name,
                    "Server"
                )

            ConfigWriteMany(
                ServerKey,
                Map(
                    "Name", Name,
                    "Executable", ServerValue,
                    "Address", "127.0.0.1",
                    "Port", LegacyLlamaPort,
                    "Args", ""
                )
            )

            ServerList.Push(
                ServerKey
            )

            ServersByExecutable[
                ExecutableKey
            ] := ServerKey

            ServerListChanged := true
        }


        ; Model now references the registered server.
        ConfigWrite(
            ModelKey,
            "Server",
            ServerKey
        )
    }


    if ServerListChanged {
        ConfigWriteList(
            "General",
            "ServerList",
            ServerList
        )
    }
}

; ============================================================
; CONFIG.INI API
; ============================================================

ConfigRead(Section, Key, Default := "") {
    global ConfigFile

	return IniRead(
        ConfigFile,
        Section,
        Key,
        Default
    )
}


ConfigWrite(Section, Key, Value) {
    global ConfigFile

    IniWrite(
        Value,
        ConfigFile,
        Section,
        Key
    )
}

ConfigWriteMany(Section, Values) {
    for Key, Value in Values
        ConfigWrite(Section, Key, Value)
}

ListContainsValue(List, Value) {
    Value := StrLower(
        Trim(Value)
    )

    for Existing in List {
        if StrLower(Existing) = Value
            return true
    }

    return false
}


RemoveListValue(List, Value) {
    Value := StrLower(
        Trim(Value)
    )

    for Index, Existing in List {
        if StrLower(Existing) != Value
            continue

        List.RemoveAt(Index)
        return true
    }

    return false
}


LooksLikeConfigPath(Value) {
    Value := Trim(Value)

    if Value = ""
        return false

    return RegExMatch(
        Value,
        "i)^(?:[A-Z]:[\\/]|\\\\|//|\.[\\/])"
    )
        || InStr(Value, "\")
        || InStr(Value, "/")
}


NormalizeConfigPath(Path) {
    Path := Trim(Path)

    return StrLower(
        StrReplace(
            Path,
            "/",
            "\"
        )
    )
}


ConfigReadList(
    Section,
    Key,
    Default := ""
) {
    Raw := Trim(
        ConfigRead(
            Section,
            Key,
            Default
        )
    )

    if Raw = ""
        return []

    Items := []
    Seen := Map()

    for Item in StrSplit(Raw, "|") {
        Item := Trim(Item)

        if Item = ""
            continue

        Canonical := StrLower(Item)

        if Seen.Has(Canonical)
            continue

        Seen[Canonical] := true
        Items.Push(Item)
    }

    return Items
}


ConfigWriteList(
    Section,
    Key,
    Values
) {
    Text := ""

    for Value in Values {
        if Text != ""
            Text .= "|"

        Text .= Value
    }

    ConfigWrite(
        Section,
        Key,
        Text
    )
}


ConfigDeleteKey(
    Section,
    Key
) {
    global ConfigFile

    IniDelete(
        ConfigFile,
        Section,
        Key
    )
}


ConfigDeleteSection(Section) {
    global ConfigFile

    IniDelete(
        ConfigFile,
        Section
    )
}


ConfigSections() {
    global ConfigFile

    if !FileExist(ConfigFile)
        return []

    try Text := IniRead(
        ConfigFile
    )
    catch
        return []

    Text := Trim(
        Text,
        " `t`r`n"
    )

    if Text = ""
        return []

    Sections := []

    for Section in StrSplit(
        StrReplace(
            Text,
            "`r"
        ),
        "`n"
    ) {
        Section := Trim(Section)

        if Section != ""
            Sections.Push(Section)
    }

    return Sections
}

ConfigReadInteger(
    Section,
    Key,
    Default,
    Minimum := "",
    Maximum := ""
) {
    Value := ConfigRead(
        Section,
        Key,
        Default
    )

    if !IsInteger(Value)
        Value := Default

    Value += 0

    if Minimum != ""
        Value := Max(
            Minimum,
            Value
        )

    if Maximum != ""
        Value := Min(
            Maximum,
            Value
        )

    return Value
}

ConfigReadBoolean(
    Section,
    Key,
    Default := false
) {
    Value := StrLower(
        Trim(
            ConfigRead(
                Section,
                Key,
                Default ? "true" : "false"
            )
        )
    )

    return Value = "1"
        || Value = "true"
        || Value = "yes"
        || Value = "on"
}

SaveModelDefaults(ModelKey, ServerKey, Context, Cache, McpDirectories) {
    global Models

    Model := Models[ModelKey]

    SaveModel(
        ModelKey, Model.Name, Model.Model, ServerKey,
        Context, Cache, Model.Args, McpDirectories
    )
}


SaveModel(ModelKey, Name, ModelPath, ServerKey, Context := 32768, Cache := "q4_0", Args := "", McpDirectories := "") {
    global Models, ModelList

    Model := {
        Name: Name,
        ServerKey: ServerKey,
        Model: ModelPath,
        Context: Context + 0,
        Cache: Cache,
        Args: Args,
        McpDirectories: McpDirectories
    }

    ConfigWriteMany(
        ModelKey,
        Map(
            "Name", Model.Name,
            "Server", Model.ServerKey,
            "Model", Model.Model,
            "Context", Model.Context,
            "Cache", Model.Cache,
            "Args", Model.Args,
            "McpDirectories", Model.McpDirectories
        )
    )

    if !ListContainsValue(ModelList, ModelKey) {
        ModelList.Push(ModelKey)
        ConfigWriteList("General", "ModelList", ModelList)
    }

    Models[ModelKey] := Model
    return ModelKey
}


AddModel(Name, ModelPath, ServerKey) {
    ModelKey := GenerateConfigKey(Name, "Model")
    return SaveModel(ModelKey, Name, ModelPath, ServerKey)
}


DeleteModel(ModelKey) {
    global Models, ModelList, LastModel

    if !ListContainsValue(ModelList, ModelKey)
        return false

    ConfigDeleteSection(ModelKey)
    RemoveListValue(ModelList, ModelKey)
    ConfigWriteList("General", "ModelList", ModelList)

    if Models.Has(ModelKey)
        Models.Delete(ModelKey)

    if LastModel = ModelKey {
        LastModel := ModelList.Length ? ModelList[1] : ""

        if LastModel != ""
            SaveLastModel(LastModel)
        else
            ConfigDeleteKey("State", "LastModel")
    }

    return true
}

SaveMcpDefaults(Enabled, Address, Port, Directories) {
    global McpEnabled, McpAddress, McpPort
    global McpDirectories

    Address := Trim(Address)

    ConfigWriteMany(
        "MCP",
        Map(
            "Enabled", Enabled ? "true" : "false",
            "Address", Address,
            "Port", Port,
            "GlobalDirectories", Directories
        )
    )

    ; Retire keys from earlier MCP configuration shapes.
    try ConfigDeleteKey(
        "MCP",
        "Directories"
    )

    try ConfigDeleteKey(
        "MCP",
        "Mode"
    )

    McpEnabled := Enabled
    McpAddress := Address
    McpPort := Port
    McpDirectories := Directories
}

SaveLastModel(ModelKey) {
    global LastModel

	ConfigWrite(
		"State",
		"LastModel",
		ModelKey
	)

    LastModel := ModelKey
}

ConfigKeyInUse(Key) {
    global ModelList
    global ServerList

    Key := StrLower(
        Trim(Key)
    )

    if Key = ""
        return true

    static Reserved := Map(
        "general", true,
        "state", true,
        "mcp", true,
        "logging", true
    )

    if Reserved.Has(Key)
        return true

    for Existing in ModelList {
        if StrLower(Existing) = Key
            return true
    }

    for Existing in ServerList {
        if StrLower(Existing) = Key
            return true
    }

    for Existing in ConfigSections() {
        if StrLower(Existing) = Key
            return true
    }

    return false
}


GenerateConfigKey(
    Name,
    Fallback := "Item"
) {
    Name := Trim(Name)

    Base := RegExReplace(
        Name,
        "\s.*$"
    )

    Base := RegExReplace(
        Base,
        "[^A-Za-z0-9_.-]",
        ""
    )

    if !RegExMatch(Base, "[A-Za-z0-9]")
        Base := Fallback

    Candidate := Base
    Suffix := 2

    while ConfigKeyInUse(Candidate) {
        Candidate :=
            Base
            . Suffix

        Suffix += 1
    }

    return Candidate
}

DeriveServerName(Executable) {
    SplitPath(
        Executable,
        &FileName,
        &Directory,
        &Extension,
        &NameNoExt
    )

    if StrLower(NameNoExt) = "llama-server"
    && Directory != "" {
        SplitPath(
            Directory,
            &FolderName
        )

        if FolderName != ""
            return FolderName
    }

    if NameNoExt != ""
        return NameNoExt

    return "Llama Server"
}

; ============================================================
;  TRAY MENU
; ============================================================

A_TrayMenu.Delete()

A_TrayMenu.Add("Open Controller", ShowController)

A_TrayMenu.Add()

A_TrayMenu.Add("Shutdown All", ShutdownAll)

A_TrayMenu.Default := "Open Controller"
A_TrayMenu.ClickCount := 2

A_IconTip := "Local AI Controller"

; ============================================================
;  STARTUP WINDOW
; ============================================================

MainGui := Gui(, "Local AI")
MainGui.BackColor := BaseColor
MainGui.MarginX := 26
MainGui.MarginY := 22

ApplyDarkWindow(MainGui)

MainGui.SetFont("s16 Bold c" TextColor, "Segoe UI")
MainGui.AddText("xm w520 Center", "LOCAL AI")

MainGui.SetFont("s12 Norm c" TextColor, "Segoe UI")

MainGui.AddText("xm y+24", "Model")

ModelNames := []
InitialIndex := 1

InitialModelKey :=
    LastModel != ""
    && Models.Has(LastModel)
        ? LastModel
        : ModelList[1]

for Index, Key in ModelList {
    ModelNames.Push(
        Models[Key].Name
    )

    if Key = InitialModelKey
        InitialIndex := Index
}

MainModelControl := MainGui.AddDropDownList(
    "xm y+7 w520 +0x210",
    ModelNames
)

MainModelControl.Choose(InitialIndex)
ApplyDarkControl(MainModelControl)

BuildActiveGui()


; ------------------------------------------------------------
;  DEFAULT INFORMATION
; ------------------------------------------------------------

MainGui.SetFont("s11 c" MutedColor, "Segoe UI")

MainContextText := MainGui.AddText(
    "xm y+16 w260",
    ""
)

MainCacheText := MainGui.AddText(
    "x+0 yp w260",
    ""
)


; ------------------------------------------------------------
;  MCP INFORMATION
; ------------------------------------------------------------

MainGui.SetFont("s12 c" TextColor, "Segoe UI")
MainGui.AddText("xm y+22", "MCP Access")

MainGui.SetFont("s11 c" MutedColor, "Segoe UI")

MainMcpText := MainGui.AddText(
    "xm y+7 w520",
    DisplayDirectories(McpDirectories)
)

; ------------------------------------------------------------
;  BUTTONS
; ------------------------------------------------------------

MainGui.SetFont("s12 c" TextColor, "Segoe UI")

StartButton := MainGui.AddButton(
    "xm y+26 w250 h46",
    "Start"
)

ConfigButton := MainGui.AddButton(
    "x+20 yp w250 h46",
    "Configure..."
)

MakeOwnerDrawButton(StartButton)
MakeOwnerDrawButton(ConfigButton)

StartButton.OnEvent("Click", StartSelected)
ConfigButton.OnEvent("Click", OpenConfig)
MainModelControl.OnEvent("Change", UpdateMainModelInfo)

MainGui.OnEvent("Close", HideController)

UpdateMainModelInfo()

MainGui.Show("w572")


; ============================================================
;  STARTUP MODEL INFORMATION
; ============================================================

UpdateMainModelInfo(*) {
    global MainModelControl, MainContextText, MainCacheText
    global ModelList, Models

    Key := ModelList[MainModelControl.Value]
    Model := Models[Key]

    MainContextText.Text := "Context:  " Model.Context
    MainCacheText.Text := "KV cache:  " Model.Cache
}


; ============================================================
;  START SELECTED MODEL WITH ITS DEFAULTS
; ============================================================

StartSelected(*) {
    global MainModelControl
    global ModelList, Models
    global McpDirectories

    Key := ModelList[
        MainModelControl.Value
    ]

    Model := Models[Key]

    EnterActiveView(
        Key,
        Model.Context,
        Model.Cache,
        McpDirectories
    )

    LaunchAI(
        Key,
        "",
        "",
        McpDirectories
    )
}

; ============================================================
;  REUSABLE CONFIG PANELS
; ============================================================

class ModelConfigPanel {
    __New(GuiObj, X, Y, Width, ModelKey, Context := "", Cache := "", ServerKey := "") {
        global SecondaryColor, TextColor, MutedColor

        this.Gui := GuiObj
        this.Width := Width
        this.ServerKeys := []

        GuiObj.SetFont("s12 Norm c" TextColor, "Segoe UI")
        GuiObj.AddText("x" X " y" Y, "Model")
        Y += 29

        this.ModelControl := GuiObj.AddDropDownList("x" X " y" Y " w" (Width - 68) " +0x210", [])
        ApplyDarkControl(this.ModelControl)

        GuiObj.SetFont("s11 c" TextColor, "Segoe UI")
        this.AddModelButton := GuiObj.AddButton("x+8 yp w26 h26", "+")
        GuiObj.SetFont("s13 c" TextColor, "Segoe UI")
        this.DeleteModelButton := GuiObj.AddButton("x+8 yp w26 h26", "×")
        MakeOwnerDrawButton(this.AddModelButton)
        MakeOwnerDrawButton(this.DeleteModelButton)

        Y += 50
        GuiObj.SetFont("s12 Norm c" TextColor, "Segoe UI")
        GuiObj.AddText("x" X " y" Y, "Llama server")
        Y += 29

        this.ServerControl := GuiObj.AddDropDownList("x" X " y" Y " w" (Width - 34) " +0x210", [])
        ApplyDarkControl(this.ServerControl)

        GuiObj.SetFont("s11 c" TextColor, "Segoe UI")
        this.ServerManagerButton := GuiObj.AddButton("x+8 yp w26 h26", "+")
        MakeOwnerDrawButton(this.ServerManagerButton)

        Y += 50
        GuiObj.SetFont("s12 Norm c" TextColor, "Segoe UI")
        GuiObj.AddText("x" X " y" Y, "Context")
        Y += 29

        this.ContextControl := GuiObj.AddComboBox(
            "x" X " y" Y " w" Width " +0x210 Background" SecondaryColor " c" TextColor,
            ["16384", "24576", "32768"]
        )
        ApplyDarkControl(this.ContextControl)

        Y += 50
        GuiObj.AddText("x" X " y" Y, "KV cache")
        Y += 29

        this.CacheControl := GuiObj.AddDropDownList(
            "x" X " y" Y " w" Width " +0x210",
            ["f16", "q8_0", "q4_0"]
        )
        ApplyDarkControl(this.CacheControl)

        Y += 50
        GuiObj.AddText("x" X " y" Y, "Model MCP directories")
        Y += 25

        GuiObj.SetFont("s10 c" MutedColor, "Segoe UI")
        GuiObj.AddText("x" X " y" Y " w" Width, "Additional filesystem roots owned by this model.")
        Y += 25

        GuiObj.SetFont("s12 Norm c" TextColor, "Segoe UI")
        this.McpDirectoriesEdit := GuiObj.AddEdit(
            "x" X " y" Y " w" Width " r3 -VScroll Background" SecondaryColor " c" TextColor,
            ""
        )

        Y += 82
        GuiObj.SetFont("s10 c" MutedColor, "Segoe UI")
        this.DefaultsText := GuiObj.AddText("x" X " y" Y " w" Width " h38", "")
        this.Bottom := Y + 38

        this.ModelControl.OnEvent("Change", ObjBindMethod(this, "ResetToModelDefaults"))
        this.AddModelButton.OnEvent("Click", ObjBindMethod(this, "OpenAddModel"))
        this.DeleteModelButton.OnEvent("Click", ObjBindMethod(this, "DeleteSelectedModel"))
        this.ServerManagerButton.OnEvent("Click", ObjBindMethod(this, "OpenServerManager"))

        this.RefreshModels(ModelKey, false)
        this.SetValues(ModelKey, Context, Cache, ServerKey)
    }


    RefreshModels(PreferredModelKey := "", ResetValues := true) {
        global Models, ModelList

        if PreferredModelKey = ""
            PreferredModelKey := this.GetModelKey()

        Names := []
        SelectedIndex := 0

        for Index, Key in ModelList {
            Names.Push(Models[Key].Name)

            if Key = PreferredModelKey
                SelectedIndex := Index
        }

        this.ModelControl.Delete()
        if Names.Length
            this.ModelControl.Add(Names)

        if !SelectedIndex && Names.Length
            SelectedIndex := 1

        this.ModelControl.Choose(SelectedIndex)

        HasModel := SelectedIndex > 0
        this.DeleteModelButton.Enabled := HasModel && ModelList.Length > 1
        this.ServerControl.Enabled := HasModel
        this.ContextControl.Enabled := HasModel
        this.CacheControl.Enabled := HasModel
        this.McpDirectoriesEdit.Enabled := HasModel

        if ResetValues && HasModel
            this.ResetToModelDefaults()
    }


    RefreshServers(PreferredServerKey := "") {
        global Servers, ServerList

        if PreferredServerKey = ""
            PreferredServerKey := this.GetServerKey()

        Names := []
        Keys := []
        SelectedIndex := 0

        if PreferredServerKey != "" && !Servers.Has(PreferredServerKey) {
            Keys.Push(PreferredServerKey)
            Names.Push("[Missing] " PreferredServerKey)
            SelectedIndex := 1
        }

        for ServerKey in ServerList {
            if !Servers.Has(ServerKey)
                continue

            Keys.Push(ServerKey)
            Names.Push(Servers[ServerKey].Name)

            if ServerKey = PreferredServerKey
                SelectedIndex := Keys.Length
        }

        this.ServerControl.Delete()
        if Names.Length
            this.ServerControl.Add(Names)

        this.ServerKeys := Keys

        if !SelectedIndex && Keys.Length
            SelectedIndex := 1

        this.ServerControl.Choose(SelectedIndex)
    }


    SetValues(ModelKey, Context := "", Cache := "", ServerKey := "") {
        global Models, ModelList

        if !Models.Has(ModelKey)
            return

        for Index, Key in ModelList {
            if Key = ModelKey {
                this.ModelControl.Choose(Index)
                break
            }
        }

        Model := Models[ModelKey]
        this.RefreshServers(ServerKey != "" ? ServerKey : Model.ServerKey)
        this.ContextControl.Text := Context != "" ? Context : Model.Context
        ChooseCache(this.CacheControl, Cache != "" ? Cache : Model.Cache)
        this.McpDirectoriesEdit.Text := DirectoriesForEdit(Model.McpDirectories)
        this.UpdateDefaultsText()
    }


    ResetToModelDefaults(*) {
        global Models

        Key := this.GetModelKey()
        if Key = "" || !Models.Has(Key)
            return

        Model := Models[Key]
        this.RefreshServers(Model.ServerKey)
        this.ContextControl.Text := Model.Context
        ChooseCache(this.CacheControl, Model.Cache)
        this.McpDirectoriesEdit.Text := DirectoriesForEdit(Model.McpDirectories)
        this.UpdateDefaultsText()
    }


    UpdateDefaultsText() {
        global Models, Servers

        Key := this.GetModelKey()
        if Key = "" || !Models.Has(Key) {
            this.DefaultsText.Text := ""
            return
        }

        Model := Models[Key]
        ServerName := Servers.Has(Model.ServerKey)
            ? Servers[Model.ServerKey].Name
            : Model.ServerKey != ""
                ? "Missing: " Model.ServerKey
                : "Not assigned"

        this.DefaultsText.Text :=
            "Configured defaults:  " Model.Context " context  /  " Model.Cache " KV`nServer:  " ServerName
    }


    GetModelKey() {
        global ModelList
        Index := this.ModelControl.Value
        return Index >= 1 && Index <= ModelList.Length ? ModelList[Index] : ""
    }


    GetServerKey() {
        Index := this.ServerControl.Value
        return Index >= 1 && Index <= this.ServerKeys.Length ? this.ServerKeys[Index] : ""
    }


    GetValues() {
        ModelKey := this.GetModelKey()
        ServerKey := this.GetServerKey()
        Context := Trim(this.ContextControl.Text)

        if ModelKey = "" {
            MsgBox("Select or add a model.", "Local AI", "Icon!")
            return false
        }

        if ServerKey = "" {
            MsgBox("Select a llama server for this model.", "Local AI", "Icon!")
            return false
        }

        if !IsInteger(Context) || Context <= 0 {
            MsgBox("Context must be a positive integer.", "Local AI", "Icon!")
            return false
        }

        return {
            ModelKey: ModelKey,
            ServerKey: ServerKey,
            Context: Context + 0,
            Cache: this.CacheControl.Text,
            McpDirectories: DirectoriesFromEdit(this.McpDirectoriesEdit.Text)
        }
    }


    OpenAddModel(*) {
        OpenAddModelDialog(this.Gui, ObjBindMethod(this, "ModelAdded"))
    }


    ModelAdded(ModelKey) {
        this.RefreshModels(ModelKey)
        RefreshMainModelControl(ModelKey)
    }


    DeleteSelectedModel(*) {
        global Models, ModelList
        global ControllerMode, ActiveModelKey

        ModelKey := this.GetModelKey()
        if ModelKey = "" || !Models.Has(ModelKey)
            return

        if ModelList.Length <= 1 {
            MsgBox(
                "At least one registered model must remain until first-run Setup is added.",
                "Delete Model",
                "Icon!"
            )
            return
        }

        if ControllerMode = "active" && ModelKey = ActiveModelKey {
            MsgBox(
                "The model currently assigned to the Active session cannot be deleted.",
                "Delete Model",
                "Icon!"
            )
            return
        }

        Model := Models[ModelKey]
        MainModelKey := GetMainSelectedModelKey()
        OldIndex := this.ModelControl.Value

        if MsgBox("Delete model '" Model.Name "'?", "Delete Model", "YesNo Icon?") != "Yes"
            return

        DeleteModel(ModelKey)

        PreferredModelKey := ModelList[Min(OldIndex, ModelList.Length)]
        this.RefreshModels(PreferredModelKey)

        if MainModelKey = ModelKey
            MainModelKey := PreferredModelKey

        RefreshMainModelControl(MainModelKey)
    }


    OpenServerManager(*) {
        OpenServerManager(this.Gui, this.GetServerKey(), ObjBindMethod(this, "ServerRegistryChanged"))
    }


    ServerRegistryChanged(*) {
        CurrentServerKey := this.GetServerKey()
        this.RefreshServers(CurrentServerKey)
        this.UpdateDefaultsText()
    }
}

class McpConfigPanel {
    __New(GuiObj, X, Y, Width, Enabled, Address, Port, Directories) {
        global SecondaryColor, TextColor, MutedColor

        this.Gui := GuiObj
        this.X := X
        this.Y := Y
        this.Width := Width

        GuiObj.SetFont("s12 Norm c" TextColor, "Segoe UI")
        GuiObj.AddText("x" X " y" Y, "Use MCP")
        Y += 29

        this.EnabledControl := GuiObj.AddDropDownList(
            "x" X " y" Y " w" Width " +0x210",
            ["Enabled", "Disabled"]
        )
        ApplyDarkControl(this.EnabledControl)

        Y += 50
        AddressWidth := Width - 124

        GuiObj.AddText("x" X " y" Y, "Bind address")
        GuiObj.AddText("x" (X + AddressWidth + 20) " yp", "Port")
        Y += 29

        this.AddressEdit := GuiObj.AddEdit(
            "x" X " y" Y
            . " w" AddressWidth
            . " Background" SecondaryColor
            . " c" TextColor,
            Address
        )

        this.PortEdit := GuiObj.AddEdit(
            "x" (X + AddressWidth + 20) " yp"
            . " w104"
            . " Background" SecondaryColor
            . " c" TextColor,
            Port
        )

        Y += 50
        GuiObj.AddText("x" X " y" Y, "Global MCP directories")
        Y += 25

        GuiObj.SetFont("s10 c" MutedColor, "Segoe UI")
        this.DirectoryHelp := GuiObj.AddText(
            "x" X " y" Y " w" Width,
            "Available to every model through the local filesystem MCP."
        )
        Y += 25

        GuiObj.SetFont("s11 c" TextColor, "Segoe UI")
        this.DirectoryEdit := GuiObj.AddEdit(
            "x" X " y" Y
            . " w" Width
            . " r4 -VScroll Background"
            . SecondaryColor
            . " c"
            . TextColor,
            DirectoriesForEdit(Directories)
        )

        this.Bottom := Y + 94

        this.SetValues(
            Enabled,
            Address,
            Port,
            Directories
        )
    }


    SetValues(Enabled, Address, Port, Directories) {
        this.EnabledControl.Choose(Enabled ? 1 : 2)
        this.AddressEdit.Text := Address
        this.PortEdit.Text := Port
        this.SetDirectories(Directories)
    }


    GetValues() {
        Enabled := this.EnabledControl.Value = 1
        Address := Trim(this.AddressEdit.Text)
        Port := Trim(this.PortEdit.Text)
        Directories := this.GetDirectories()

        if Enabled && Address = "" {
            MsgBox(
                "MCP bind address cannot be blank while MCP is enabled.",
                "MCP Access",
                "Icon!"
            )

            return false
        }

        if !IsInteger(Port) || Port < 1 || Port > 65535 {
            MsgBox(
                "MCP port must be an integer from 1 through 65535.",
                "MCP Access",
                "Icon!"
            )

            return false
        }

        return {
            Enabled: Enabled,
            Address: Address,
            Port: Port + 0,
            Directories: Directories
        }
    }


    GetDirectories() {
        return DirectoriesFromEdit(
            this.DirectoryEdit.Text
        )
    }


    SetDirectories(Directories) {
        this.DirectoryEdit.Text :=
            DirectoriesForEdit(
                Directories
            )
    }
}

; ============================================================
;  MASTER CONFIGURATION
; ============================================================

OpenConfig(*) {
    global MainGui
    global MainModelControl
    global ModelList
    global McpEnabled, McpAddress, McpPort
    global McpDirectories
    global BaseColor, TextColor

    ConfigGui := Gui(
        ,
        "Configure Local AI"
    )
	
	if !BeginConfigDialog(
		ConfigGui,
		MainGui
	)
		return

    ConfigGui.BackColor := BaseColor
    ConfigGui.MarginX := 26
    ConfigGui.MarginY := 22

    ApplyDarkWindow(ConfigGui)


    ; --------------------------------------------------------
    ;  TITLE
    ; --------------------------------------------------------

    ConfigGui.SetFont(
        "s16 Bold c" TextColor,
        "Segoe UI"
    )

    ConfigGui.AddText(
        "xm w520 Center",
        "CONFIGURE LOCAL AI"
    )


    ; --------------------------------------------------------
    ;  PANELS
    ; --------------------------------------------------------

    ModelKey := ModelList[
        MainModelControl.Value
    ]

    ModelPanel := ModelConfigPanel(
        ConfigGui,
        26,
        76,
        520,
        ModelKey
    )

    McpPanel := McpConfigPanel(
        ConfigGui,
        26,
        ModelPanel.Bottom + 20,
        520,
        McpEnabled,
        McpAddress,
        McpPort,
        McpDirectories
    )


    ; --------------------------------------------------------
    ;  BUTTONS
    ; --------------------------------------------------------

    ConfigGui.SetFont(
        "s12 c" TextColor,
        "Segoe UI"
    )

    StartButton := ConfigGui.AddButton(
        "x26 y" McpPanel.Bottom + 24
        . " w250 h44",
        "Start"
    )

    CancelButton := ConfigGui.AddButton(
        "x296 yp w250 h44",
        "Cancel"
    )

    MakeOwnerDrawButton(StartButton)
    MakeOwnerDrawButton(CancelButton)


    StartButton.OnEvent(
        "Click",
        (*) => StartMasterConfig(
            ConfigGui,
            ModelPanel,
            McpPanel
        )
    )

	CancelButton.OnEvent(
		"Click",
		(*) => EndConfigDialog(
			ConfigGui,
			MainGui
		)
	)

	ConfigGui.OnEvent(
		"Close",
		(*) => EndConfigDialog(
			ConfigGui,
			MainGui
		)
	)

	ShowRelative(
		ConfigGui,
		MainGui
	)
}


StartMasterConfig(
    ConfigGui,
    ModelPanel,
    McpPanel
) {
    Values := ModelPanel.GetValues()

    if !Values
        return

    McpValues := McpPanel.GetValues()

    if !McpValues
        return

    Directories := McpValues.Directories

    EndConfigDialog(
        ConfigGui,
        MainGui,
        false
    )

    EnterActiveView(
        Values.ModelKey,
        Values.Context,
        Values.Cache,
        Directories,
        Values.ServerKey
    )

    LaunchAI(
        Values.ModelKey,
        Values.Context,
        Values.Cache,
        Directories,
        Values.ServerKey
    )
}

; ============================================================
;  ACTIVE WINDOW
; ============================================================

BuildActiveGui() {
    global ActiveGui

    global ActiveLlamaStatus
    global ActiveLlamaName
    global ActiveLlamaDetails
    global ActiveLlamaStartButton
    global ActiveLlamaRestartButton
    global ActiveLlamaStopButton
	global ActiveLlamaEditButton

    global ActiveMcpStatus
    global ActiveMcpName
    global ActiveMcpDetails
    global ActiveMcpEditButton
    global ActiveMcpStartButton
    global ActiveMcpRestartButton
    global ActiveMcpStopButton

    global ActiveViewConsolesButton
	global ActiveOpenChatButton
	global ActiveShutdownButton

    global BaseColor, TextColor, MutedColor

    ActiveGui := Gui(, "Local AI")
    ActiveGui.BackColor := BaseColor
    ActiveGui.MarginX := 26
    ActiveGui.MarginY := 22

    ApplyDarkWindow(ActiveGui)


    ; --------------------------------------------------------
    ;  TITLE
    ; --------------------------------------------------------

    ActiveGui.SetFont(
        "s16 Bold c" TextColor,
        "Segoe UI"
    )

    ActiveGui.AddText(
        "xm w520 Center",
        "LOCAL AI"
    )


    ; --------------------------------------------------------
    ;  MODEL
    ; --------------------------------------------------------

    ActiveGui.SetFont(
        "s11 Bold c" MutedColor,
        "Segoe UI"
    )

    ActiveGui.AddText(
        "xm y+26",
        "MODEL"
    )

    ActiveGui.SetFont(
        "s12 Norm c" TextColor,
        "Segoe UI"
    )

    ActiveLlamaStatus := ActiveGui.AddText(
        "xm y+10 w105 h30",
        "○ Offline"
    )

	ActiveLlamaName := ActiveGui.AddText(
		"x+8 yp w274 h30",
		""
	)

	ActiveGui.SetFont("s11 c" TextColor, "Segoe UI")
	ActiveLlamaEditButton := ActiveGui.AddButton(
		"x+8 yp-4 w26 h26",
		"…"
	)

	ActiveLlamaStartButton := ActiveGui.AddButton(
		"x+6 yp w26 h26",
		"▶"
	)

	ActiveGui.SetFont("s12 c" TextColor, "Segoe UI")
	ActiveLlamaRestartButton := ActiveGui.AddButton(
		"x+6 yp w26 h26",
		"↻"
	)

	ActiveGui.SetFont("s13 c" TextColor, "Segoe UI")
	ActiveLlamaStopButton := ActiveGui.AddButton(
		"x+6 yp w26 h26",
		"×"
	)

    MakeOwnerDrawButton(ActiveLlamaEditButton)
	MakeOwnerDrawButton(ActiveLlamaStartButton)
    MakeOwnerDrawButton(ActiveLlamaRestartButton)
    MakeOwnerDrawButton(ActiveLlamaStopButton)

    ActiveGui.SetFont("s10 c" MutedColor,"Segoe UI")

    ActiveLlamaDetails := ActiveGui.AddText(
        "xm+113 y+4 w407 h24",
        ""
    )


    ; --------------------------------------------------------
    ;  MCP
    ; --------------------------------------------------------

    ActiveGui.SetFont(
        "s11 Bold c" MutedColor,
        "Segoe UI"
    )

    ActiveGui.AddText(
        "xm y+28",
        "MCP"
    )

    ActiveGui.SetFont(
        "s12 Norm c" TextColor,
        "Segoe UI"
    )

    ActiveMcpStatus := ActiveGui.AddText(
        "xm y+10 w105 h30",
        "○ Offline"
    )

    ActiveMcpName := ActiveGui.AddText(
        "x+8 yp w274 h30",
        "Filesystem"
    )

	ActiveGui.SetFont("s11 c" TextColor, "Segoe UI")
    ActiveMcpEditButton := ActiveGui.AddButton(
        "x+8 yp-5 w26 h26",
        "…"
    )

    ActiveMcpStartButton := ActiveGui.AddButton(
        "x+6 yp w26 h26",
        "▶"
    )

	ActiveGui.SetFont("s12 c" TextColor, "Segoe UI")
    ActiveMcpRestartButton := ActiveGui.AddButton(
        "x+6 yp w26 h26",
        "↻"
    )
	
	ActiveGui.SetFont("s13 c" TextColor, "Segoe UI")
    ActiveMcpStopButton := ActiveGui.AddButton(
        "x+6 yp w26 h26",
        "×"
    )

    MakeOwnerDrawButton(ActiveMcpEditButton)
    MakeOwnerDrawButton(ActiveMcpStartButton)
    MakeOwnerDrawButton(ActiveMcpRestartButton)
    MakeOwnerDrawButton(ActiveMcpStopButton)

    ActiveGui.SetFont("s10 c" MutedColor,"Segoe UI")

    ActiveMcpDetails := ActiveGui.AddText(
        "xm+113 y+4 w407 h66",
        ""
    )


    ; --------------------------------------------------------
    ;  BUTTONS
    ; --------------------------------------------------------

    ActiveGui.SetFont(
        "s12 c" TextColor,
        "Segoe UI"
    )

	ActiveViewConsolesButton := ActiveGui.AddButton(
		"xm y+22 w180 h44",
		"View Consoles"
	)

	ActiveOpenChatButton := ActiveGui.AddButton(
		"x+10 yp w160 h44",
		"Open Chat"
	)

	ActiveShutdownButton := ActiveGui.AddButton(
		"x+10 yp w160 h44",
		"Shutdown"
	)

	MakeOwnerDrawButton(ActiveViewConsolesButton)
	MakeOwnerDrawButton(ActiveOpenChatButton)
	MakeOwnerDrawButton(ActiveShutdownButton)

    ; --------------------------------------------------------
    ;  EVENTS
    ; --------------------------------------------------------

	ActiveLlamaEditButton.OnEvent(
		"Click",
		OpenModelEditor
	)

    ActiveLlamaStartButton.OnEvent(
        "Click",
        StartActiveLlama
    )

    ActiveLlamaRestartButton.OnEvent(
        "Click",
        RestartActiveLlama
    )

    ActiveLlamaStopButton.OnEvent(
        "Click",
        StopActiveLlama
    )

    ActiveMcpEditButton.OnEvent(
        "Click",
        OpenMcpEditor
    )

    ActiveMcpStartButton.OnEvent(
        "Click",
        StartActiveMcp
    )

    ActiveMcpRestartButton.OnEvent(
        "Click",
        RestartActiveMcp
    )

    ActiveMcpStopButton.OnEvent(
        "Click",
        StopActiveMcp
    )

	ActiveViewConsolesButton.OnEvent(
		"Click",
		OpenConsoleViewer
	)

	ActiveOpenChatButton.OnEvent(
		"Click",
		OpenChat
	)

	ActiveShutdownButton.OnEvent(
		"Click",
		ShutdownAll
	)

    ActiveGui.OnEvent(
        "Close",
        HideController
    )
}

; ============================================================
;  MODEL EDITOR
; ============================================================

OpenModelEditor(*) {
    global ActiveModelKey
    global ActiveServerKey
    global ActiveContext
    global ActiveCache

    global BaseColor, TextColor

    EditorGui := Gui(
        ,
        "Model Settings"
    )

	if !BeginConfigDialog(
		EditorGui,
		ActiveGui
	)
		return

    EditorGui.BackColor := BaseColor
    EditorGui.MarginX := 24
    EditorGui.MarginY := 20

    ApplyDarkWindow(EditorGui)


    EditorGui.SetFont(
        "s14 Bold c" TextColor,
        "Segoe UI"
    )

    EditorGui.AddText(
        "xm w480 Center",
        "MODEL SETTINGS"
    )


    ModelPanel := ModelConfigPanel(
        EditorGui,
        24,
        70,
        480,
        ActiveModelKey,
        ActiveContext,
        ActiveCache,
        ActiveServerKey
    )


    EditorGui.SetFont(
        "s12 c" TextColor,
        "Segoe UI"
    )

	ApplyButton := EditorGui.AddButton(
		"x24 y" ModelPanel.Bottom + 22
		. " w150 h42",
		"Apply"
	)

	SaveDefaultsButton := EditorGui.AddButton(
		"x189 yp w150 h42",
		"Save Defaults"
	)

	CancelButton := EditorGui.AddButton(
		"x354 yp w150 h42",
		"Cancel"
	)

	MakeOwnerDrawButton(ApplyButton)
	MakeOwnerDrawButton(SaveDefaultsButton)
	MakeOwnerDrawButton(CancelButton)

	EditorGui.OnEvent(
		"Close",
		(*) => EndConfigDialog(
			EditorGui,
			ActiveGui
		)
	)

    ApplyButton.OnEvent(
        "Click",
        (*) => ApplyModelConfig(
            EditorGui,
            ModelPanel
        )
    )
	
	SaveDefaultsButton.OnEvent(
		"Click",
		(*) => SaveModelEditorDefaults(
			ModelPanel
		)
	)

	CancelButton.OnEvent(
		"Click",
		(*) => EndConfigDialog(
			EditorGui,
			ActiveGui
		)
	)

    ShowRelative(
		EditorGui,
		ActiveGui
	)
}

ApplyModelConfig(EditorGui, ModelPanel) {
    global ActiveModelKey
    global ActiveServerKey
    global ActiveContext
    global ActiveCache

	global LlamaPid

    Values := ModelPanel.GetValues()

    if !Values
        return


    ; --------------------------------------------------------
    ;  NOTHING CHANGED
    ; --------------------------------------------------------

    if Values.ModelKey = ActiveModelKey
    && Values.ServerKey = ActiveServerKey
    && Values.Context = ActiveContext
    && Values.Cache = ActiveCache {
        EndConfigDialog(
			EditorGui,
			ActiveGui
		)
        return
    }


	OldHealthURL :=
		GetModelHealthURL(
			ActiveModelKey,
            ActiveServerKey
		)

	Status :=
		OldHealthURL != ""
			? HttpStatus(
				OldHealthURL
			)
			: 0

    Owned :=
        LlamaPid
        && ProcessExist(LlamaPid)


    ; --------------------------------------------------------
    ;  EXTERNAL SERVER
    ; --------------------------------------------------------

    if Status != 0 && !Owned {
        MsgBox(
            "The active llama-server was not started by this controller.`n`n"
            . "Its configuration cannot be changed safely.",
            "Model Settings",
            "Icon!"
        )

        return
    }


    ; --------------------------------------------------------
    ;  STORE NEW ACTIVE CONFIG
    ; --------------------------------------------------------

    ActiveModelKey := Values.ModelKey
    ActiveServerKey := Values.ServerKey
    ActiveContext := Values.Context
    ActiveCache := Values.Cache

    SyncMainModelSelection(
        ActiveModelKey
    )

    EndConfigDialog(
		EditorGui,
		ActiveGui
	)


    ; --------------------------------------------------------
    ;  APPLY
    ; --------------------------------------------------------

	if Status != 0 {
		RestartLlamaWithOfflineURL(
			OldHealthURL
		)
	}
	else {
		UpdateActiveState()
	}
}

SaveModelEditorDefaults(ModelPanel) {
    Values := ModelPanel.GetValues()

    if !Values
        return

    SaveModelDefaults(
        Values.ModelKey,
        Values.ServerKey,
        Values.Context,
        Values.Cache,
        Values.McpDirectories
    )

    ModelPanel.UpdateDefaultsText()
    UpdateMainModelInfo()
}

SyncMainModelSelection(ModelKey) {
    RefreshMainModelControl(
        ModelKey
    )
}


; ============================================================
;  MODEL REGISTRATION
; ============================================================

OpenAddModelDialog(ParentGui, OnSaved := 0) {
    global ModelRegistrationState
    global BaseColor, SecondaryColor, TextColor, MutedColor

    if IsObject(ModelRegistrationState) {
        try {
            ModelRegistrationState.Gui.Show()
            WinActivate("ahk_id " ModelRegistrationState.Gui.Hwnd)
            return
        }
        catch
            ModelRegistrationState := 0
    }

    DialogGui := Gui(, "Add Model")
    DialogGui.Opt("+Owner" ParentGui.Hwnd " -MinimizeBox -MaximizeBox")
    ParentGui.Opt("+Disabled")
    DialogGui.BackColor := BaseColor
    DialogGui.MarginX := 24
    DialogGui.MarginY := 20
    ApplyDarkWindow(DialogGui)

    DialogGui.SetFont("s14 Bold c" TextColor, "Segoe UI")
    DialogGui.AddText("xm w480 Center", "ADD MODEL")

    DialogGui.SetFont("s12 Norm c" TextColor, "Segoe UI")
    DialogGui.AddText("x24 y70", "Name")
    NameEdit := DialogGui.AddEdit("x24 y99 w480 Background" SecondaryColor " c" TextColor, "")

    DialogGui.AddText("x24 y145", "GGUF model")
    ModelPathEdit := DialogGui.AddEdit("x24 y174 w438 Background" SecondaryColor " c" TextColor, "")

    DialogGui.SetFont("s11 c" TextColor, "Segoe UI")
    BrowseButton := DialogGui.AddButton("x470 y173 w34 h26", "…")
    MakeOwnerDrawButton(BrowseButton)

    DialogGui.SetFont("s12 Norm c" TextColor, "Segoe UI")
    DialogGui.AddText("x24 y220", "Llama server")
    ServerControl := DialogGui.AddDropDownList("x24 y249 w446 +0x210", [])
    ApplyDarkControl(ServerControl)

    DialogGui.SetFont("s11 c" TextColor, "Segoe UI")
    ServerManagerButton := DialogGui.AddButton("x478 yp w26 h26", "+")
    MakeOwnerDrawButton(ServerManagerButton)

    DialogGui.SetFont("s10 c" MutedColor, "Segoe UI")
    DialogGui.AddText(
        "x24 y295 w480",
        "New models default to 32768 context, q4_0 KV cache, and no arguments."
    )

    DialogGui.SetFont("s12 c" TextColor, "Segoe UI")
    SaveButton := DialogGui.AddButton("x24 y331 w230 h42", "Add Model")
    CancelButton := DialogGui.AddButton("x274 yp w230 h42", "Cancel")
    MakeOwnerDrawButton(SaveButton)
    MakeOwnerDrawButton(CancelButton)

    ModelRegistrationState := {
        Gui: DialogGui,
        Parent: ParentGui,
        OnSaved: OnSaved,
        NameEdit: NameEdit,
        ModelPathEdit: ModelPathEdit,
        ServerControl: ServerControl,
        ServerKeys: []
    }

    BrowseButton.OnEvent("Click", (*) => BrowseModelFile(ModelPathEdit))
    ServerManagerButton.OnEvent(
        "Click",
        (*) => OpenServerManager(DialogGui, GetAddModelServerKey(), RefreshAddModelServers)
    )
    SaveButton.OnEvent("Click", SaveAddModelDialog)
    CancelButton.OnEvent("Click", CloseAddModelDialog)
    DialogGui.OnEvent("Close", CloseAddModelDialog)

    RefreshAddModelServers()
    ShowRelative(DialogGui, ParentGui)
}


RefreshAddModelServers(PreferredServerKey := "") {
    global ModelRegistrationState
    global ServerList, Servers

    if !IsObject(ModelRegistrationState)
        return

    State := ModelRegistrationState
    if PreferredServerKey = ""
        PreferredServerKey := GetAddModelServerKey()

    Names := []
    Keys := []
    SelectedIndex := 0

    for ServerKey in ServerList {
        if !Servers.Has(ServerKey)
            continue

        Keys.Push(ServerKey)
        Names.Push(Servers[ServerKey].Name)

        if ServerKey = PreferredServerKey
            SelectedIndex := Keys.Length
    }

    State.ServerControl.Delete()
    if Names.Length
        State.ServerControl.Add(Names)

    State.ServerKeys := Keys
    if !SelectedIndex && Keys.Length
        SelectedIndex := 1

    State.ServerControl.Choose(SelectedIndex)
}


GetAddModelServerKey() {
    global ModelRegistrationState

    if !IsObject(ModelRegistrationState)
        return ""

    State := ModelRegistrationState
    Index := State.ServerControl.Value
    return Index >= 1 && Index <= State.ServerKeys.Length ? State.ServerKeys[Index] : ""
}


BrowseModelFile(ModelPathEdit) {
    SelectedPath := FileSelect(1, Trim(ModelPathEdit.Text), "Select GGUF model", "GGUF models (*.gguf)")

    if SelectedPath != ""
        ModelPathEdit.Text := SelectedPath
}


SaveAddModelDialog(*) {
    global ModelRegistrationState, Servers

    if !IsObject(ModelRegistrationState)
        return

    State := ModelRegistrationState
    Name := Trim(State.NameEdit.Text)
    ModelPath := Trim(State.ModelPathEdit.Text)
    ServerKey := GetAddModelServerKey()

    if Name = "" {
        MsgBox("Enter a name for the model.", "Add Model", "Icon!")
        return
    }

    if ModelPath = "" {
        MsgBox("Enter the GGUF model location.", "Add Model", "Icon!")
        return
    }

    if !FileExist(ModelPath) {
        MsgBox(
            "Model file not found:`n`n" ModelPath,
            "Add Model",
            "Icon!"
        )
        return
    }

    if ServerKey = "" || !Servers.Has(ServerKey) {
        MsgBox("Select or register a llama server for this model.", "Add Model", "Icon!")
        return
    }

    SavedKey := AddModel(Name, ModelPath, ServerKey)
    Callback := State.OnSaved
    CloseAddModelDialog()

    if IsObject(Callback)
        Callback.Call(SavedKey)
}


CloseAddModelDialog(*) {
    global ModelRegistrationState

    if !IsObject(ModelRegistrationState)
        return

    State := ModelRegistrationState
    try State.Gui.Destroy()
    ModelRegistrationState := 0

    State.Parent.Opt("-Disabled")
    State.Parent.Show()
    try WinActivate("ahk_id " State.Parent.Hwnd)
}


GetMainSelectedModelKey() {
    global MainModelControl, ModelList

    Index := MainModelControl.Value
    return Index >= 1 && Index <= ModelList.Length ? ModelList[Index] : ""
}


RefreshMainModelControl(PreferredModelKey := "") {
    global MainModelControl
    global ModelList, Models

    Names := []
    SelectedIndex := 0

    for Index, ModelKey in ModelList {
        Names.Push(Models[ModelKey].Name)

        if ModelKey = PreferredModelKey
            SelectedIndex := Index
    }

    MainModelControl.Delete()
    if Names.Length
        MainModelControl.Add(Names)

    if !SelectedIndex && Names.Length
        SelectedIndex := 1

    MainModelControl.Choose(SelectedIndex)
    if SelectedIndex
        UpdateMainModelInfo()
}

; ============================================================
;  MCP ACCESS EDITOR
; ============================================================

OpenMcpEditor(*) {
    global ActiveGui

    OpenMcpConfigEditor(
        ActiveGui,
        true
    )
}


OpenMcpConfigEditor(ParentGui, AllowApply := false) {
    global McpEnabled, McpAddress, McpPort
    global McpDirectories
    global BaseColor, TextColor

    EditorGui := Gui(
        ,
        "MCP Access"
    )

    if !BeginConfigDialog(
        EditorGui,
        ParentGui
    )
        return

    EditorGui.BackColor := BaseColor
    EditorGui.MarginX := 24
    EditorGui.MarginY := 20

    ApplyDarkWindow(EditorGui)

    EditorGui.SetFont(
        "s14 Bold c" TextColor,
        "Segoe UI"
    )

    EditorGui.AddText(
        "xm w480 Center",
        "MCP ACCESS"
    )

    McpPanel := McpConfigPanel(
        EditorGui,
        24,
        70,
        480,
        McpEnabled,
        McpAddress,
        McpPort,
        McpDirectories
    )

    EditorGui.SetFont(
        "s12 c" TextColor,
        "Segoe UI"
    )

    if AllowApply {
        SaveButton := EditorGui.AddButton(
            "x24 y" McpPanel.Bottom + 22
            . " w150 h42",
            "Save"
        )

        SaveApplyButton := EditorGui.AddButton(
            "x189 yp w150 h42",
            "Save & Apply"
        )

        CancelButton := EditorGui.AddButton(
            "x354 yp w150 h42",
            "Cancel"
        )

        MakeOwnerDrawButton(SaveButton)
        MakeOwnerDrawButton(SaveApplyButton)
        MakeOwnerDrawButton(CancelButton)

        SaveButton.OnEvent(
            "Click",
            (*) => SaveMcpEditorOnly(
                EditorGui,
                ParentGui,
                McpPanel
            )
        )

        SaveApplyButton.OnEvent(
            "Click",
            (*) => SaveAndApplyMcpEditor(
                EditorGui,
                ParentGui,
                McpPanel
            )
        )
    }
    else {
        SaveButton := EditorGui.AddButton(
            "x24 y" McpPanel.Bottom + 22
            . " w230 h42",
            "Save"
        )

        CancelButton := EditorGui.AddButton(
            "x274 yp w230 h42",
            "Cancel"
        )

        MakeOwnerDrawButton(SaveButton)
        MakeOwnerDrawButton(CancelButton)

        SaveButton.OnEvent(
            "Click",
            (*) => SaveMcpEditorOnly(
                EditorGui,
                ParentGui,
                McpPanel
            )
        )
    }

    EditorGui.OnEvent(
        "Close",
        (*) => EndConfigDialog(
            EditorGui,
            ParentGui
        )
    )

    CancelButton.OnEvent(
        "Click",
        (*) => EndConfigDialog(
            EditorGui,
            ParentGui
        )
    )

    ShowRelative(
        EditorGui,
        ParentGui
    )
}


SaveMcpEditorConfig(McpPanel) {
    global MainMcpText
    global McpDirectories

    Values := McpPanel.GetValues()

    if !Values
        return false

    if Values.Directories != ""
    && !VerifyDirectories(Values.Directories)
        return false

    SaveMcpDefaults(
        Values.Enabled,
        Values.Address,
        Values.Port,
        Values.Directories
    )

    MainMcpText.Text :=
        DisplayDirectories(
            McpDirectories
        )

    return Values
}


SaveMcpEditorOnly(EditorGui, ParentGui, McpPanel) {
    global ControllerMode

    if !SaveMcpEditorConfig(McpPanel)
        return

    EndConfigDialog(
        EditorGui,
        ParentGui
    )

    if ControllerMode = "active"
        UpdateActiveState()
}


SaveAndApplyMcpEditor(EditorGui, ParentGui, McpPanel) {
    Values := SaveMcpEditorConfig(McpPanel)

    if !Values
        return

    EndConfigDialog(
        EditorGui,
        ParentGui
    )

    ApplySavedMcpConfiguration()
}


ApplySavedMcpConfiguration() {
    global ActiveModelKey
    global ActiveMcpConfig, ActiveMcpDirectories
    global ActiveMcpStatus
    global McpPid, McpState
    global McpStartupUntil

    Desired := GetSavedMcpConfig(
        ActiveModelKey
    )


    ; --------------------------------------------------------
    ;  EXTERNAL SERVICE
    ; --------------------------------------------------------

    ; Never commandeer an external proxy. If the saved configuration
    ; points at another endpoint, stop tracking the old one and apply
    ; the new configuration there instead.

    if McpState = "external"
    && IsObject(ActiveMcpConfig) {
        if !Desired.Enabled {
            ActiveMcpConfig := 0
            ActiveMcpDirectories := ""
            McpStartupUntil := 0
            UpdateActiveState()
            return
        }

        if !McpEndpointsMatch(
            ActiveMcpConfig,
            Desired
        ) {
            ActiveMcpConfig := 0
            ActiveMcpDirectories := ""
            McpStartupUntil := 0
            StartActiveMcp()
            return
        }

        if GetMcpConfigDifferenceState() = "" {
            UpdateActiveState()
            return
        }

        MsgBox(
            "The active MCP service was not started by this controller.`n`n"
            . "The new configuration was saved, but changes to this endpoint cannot be applied safely until that external service is stopped.",
            "MCP Access",
            "Icon!"
        )

        UpdateActiveState()
        return
    }


    ; --------------------------------------------------------
    ;  STOP OWNED RUNTIME
    ; --------------------------------------------------------

    if McpPid && ProcessExist(McpPid) {
        OldConfig := IsObject(ActiveMcpConfig)
            ? ActiveMcpConfig
            : GetSavedMcpConfig(ActiveModelKey)

        ActiveMcpStatus.Text := "◐ Restarting"

        StopProcessTree(McpPid)
        McpPid := 0

        WaitForOffline(
            GetMcpStatusURL(OldConfig),
            10000
        )
    }

    ActiveMcpConfig := 0
    ActiveMcpDirectories := ""
    McpStartupUntil := 0


    ; --------------------------------------------------------
    ;  APPLY SAVED CONFIGURATION
    ; --------------------------------------------------------

    if !Desired.Enabled {
        UpdateActiveState()
        return
    }

    StartActiveMcp()
}

; ============================================================
;  CONSOLE VIEWER
; ============================================================

OpenConsoleViewer(*) {
    global ConsoleGui
    global ConsoleActiveTab

    global ConsoleLlamaPosition
    global ConsoleMcpPosition
    global ConsoleLlamaText
    global ConsoleMcpText

	global ConsoleMinRate
	global ConsoleMaxRate
    global ConsoleEffectiveRate
    global ConsoleRateCheckInterval

    global ConsoleLlamaButton
    global ConsoleMcpButton
	global ConsoleWrapButton
	global ConsoleWrapEnabled
    global ConsoleEffectiveText
    global ConsoleRefreshControl
    global ConsoleOutput

    global ActiveGui

    global BaseColor
    global SecondaryColor
    global TextColor
    global MutedColor


    ; --------------------------------------------------------
    ;  ALREADY OPEN
    ; --------------------------------------------------------

    if IsObject(ConsoleGui) {
        try {
            ConsoleGui.Show()

            WinActivate(
                "ahk_id " ConsoleGui.Hwnd
            )

            return
        }
        catch {
            ConsoleGui := 0
        }
    }


    ; --------------------------------------------------------
    ;  RESET VIEWER STATE
    ; --------------------------------------------------------

    ConsoleActiveTab := "llama"

    ConsoleLlamaPosition := 0
    ConsoleMcpPosition := 0

    ConsoleLlamaText := ""
    ConsoleMcpText := ""
	
	ConsoleEffectiveRate :=
		ConfigReadInteger(
			"State",
			"ConsoleRefreshRate",
			ConfigReadInteger(
				"General",
				"ConsoleRefreshRate",
				250,
				ConsoleMinRate,
				ConsoleMaxRate
			),
			ConsoleMinRate,
			ConsoleMaxRate
		)

    ; --------------------------------------------------------
    ;  WINDOW
    ; --------------------------------------------------------

    ConsoleGui := Gui(
        ,
        "Local AI - Consoles"
    )

    ConsoleGui.BackColor := BaseColor
    ConsoleGui.MarginX := 22
    ConsoleGui.MarginY := 20

    ApplyDarkWindow(
        ConsoleGui
    )


	; --------------------------------------------------------
	;  TOP BAR - TABS
	; --------------------------------------------------------

	ConsoleGui.SetFont(
		"s11 c" TextColor,
		"Segoe UI"
	)

	ConsoleLlamaButton := ConsoleGui.AddButton(
		"x22 y10 w110 h34",
		"Llama"
	)

	ConsoleMcpButton := ConsoleGui.AddButton(
		"x+8 yp w90 h34",
		"MCP"
	)

	ConsoleWrapButton := ConsoleGui.AddButton(
		"x+20 yp w60 h34",
		"Wrap"
	)

	MakeOwnerDrawButton(
		ConsoleLlamaButton
	)

	MakeOwnerDrawButton(
		ConsoleMcpButton
	)

	MakeOwnerDrawButton(
		ConsoleWrapButton
	)


	; --------------------------------------------------------
	;  TOP BAR - REFRESH
	; --------------------------------------------------------

	ConsoleGui.SetFont(
		"s10 c" MutedColor,
		"Segoe UI"
	)

	ConsoleEffectiveText := ConsoleGui.AddText(
		"x732 y14 w80 Right",
		ConsoleEffectiveRate . " ms"
	)

	ConsoleGui.SetFont(
		"s10 c" TextColor,
		"Segoe UI"
	)

	ConsoleRefreshControl := ConsoleGui.AddEdit(
		"x822 y9 w100 h29 Background"
		. SecondaryColor
		. " c"
		. TextColor,
		ConsoleEffectiveRate
	)


    ; --------------------------------------------------------
    ;  LOG OUTPUT
    ; --------------------------------------------------------

	ConsoleGui.SetFont(
		"s10 c" TextColor,
		"Consolas"
	)

	ConsoleOutput := ConsoleGui.AddEdit(
		"x22 y54 w900 r30 ReadOnly -VScroll -Wrap Background"
		. SecondaryColor
		. " c"
		. TextColor,
		""
	)


    ; --------------------------------------------------------
    ;  EVENTS
    ; --------------------------------------------------------

	OnMessage(
		0x020A,  ; WM_MOUSEWHEEL
		ConsoleMouseWheel
	)


    ConsoleLlamaButton.OnEvent(
        "Click",
        (*) => SelectConsoleTab("llama")
    )

    ConsoleMcpButton.OnEvent(
        "Click",
        (*) => SelectConsoleTab("mcp")
    )
	
	ConsoleWrapButton.OnEvent(
		"Click",
		ToggleConsoleWrap
	)

    ConsoleGui.OnEvent(
        "Close",
        CloseConsoleViewer
    )


    ; --------------------------------------------------------
    ;  INITIAL STATE
    ; --------------------------------------------------------

    UpdateConsoleTabAppearance()
	UpdateConsoleWrapAppearance()

    ; Load whatever is already in both logs immediately.
    UpdateConsoleLogs()

    SetTimer(
        UpdateConsoleLogs,
        ConsoleEffectiveRate
    )

    SetTimer(
        ValidateConsoleRefreshRate,
        ConsoleRateCheckInterval
    )


    ; Non-modal. Active remains usable underneath.
    ShowRelative(
        ConsoleGui,
        ActiveGui
    )
}

; ============================================================
;  CONSOLE TABS
; ============================================================

SelectConsoleTab(Tab) {
    global ConsoleActiveTab
    global ConsoleOutput

    global ConsoleLlamaText
    global ConsoleMcpText

    if ConsoleActiveTab = Tab
        return

    ConsoleActiveTab := Tab

    if Tab = "llama"
        ConsoleOutput.Value := ConsoleLlamaText
    else
        ConsoleOutput.Value := ConsoleMcpText

    UpdateConsoleTabAppearance()
    ScrollConsoleToBottom()
}


UpdateConsoleTabAppearance() {
    global ConsoleActiveTab

    global ConsoleLlamaButton
    global ConsoleMcpButton

    global DarkButtonFillOverrides
    global SecondaryBrush


    ; Clear previous overrides.
    if DarkButtonFillOverrides.Has(
        ConsoleLlamaButton.Hwnd
    )
        DarkButtonFillOverrides.Delete(
            ConsoleLlamaButton.Hwnd
        )

    if DarkButtonFillOverrides.Has(
        ConsoleMcpButton.Hwnd
    )
        DarkButtonFillOverrides.Delete(
            ConsoleMcpButton.Hwnd
        )


    ; Active tab looks permanently pressed into the surface.
    if ConsoleActiveTab = "llama" {
        DarkButtonFillOverrides[
            ConsoleLlamaButton.Hwnd
        ] := SecondaryBrush
    }
    else {
        DarkButtonFillOverrides[
            ConsoleMcpButton.Hwnd
        ] := SecondaryBrush
    }


    RedrawDarkButton(
        ConsoleLlamaButton
    )

    RedrawDarkButton(
        ConsoleMcpButton
    )
}


RedrawDarkButton(Control) {
    DllCall(
        "user32\InvalidateRect",
        "ptr",
        Control.Hwnd,
        "ptr",
        0,
        "int",
        true
    )
}

; ============================================================
;  LOG READING
; ============================================================

ToggleConsoleWrap(*) {
    global ConsoleWrapEnabled

    ConsoleWrapEnabled :=
        !ConsoleWrapEnabled

    RebuildConsoleOutput()
    UpdateConsoleWrapAppearance()
}

RebuildConsoleOutput() {
    global ConsoleGui
    global ConsoleOutput
    global ConsoleWrapEnabled
    global ConsoleActiveTab

    global ConsoleLlamaText
    global ConsoleMcpText

    global SecondaryColor
    global TextColor


    if ConsoleActiveTab = "llama"
        Text := ConsoleLlamaText
    else
        Text := ConsoleMcpText


    ; Remove the old display control.
    ConsoleOutput.Visible := false


    ConsoleGui.SetFont(
        "s10 c" TextColor,
        "Consolas"
    )

    WrapOption :=
        ConsoleWrapEnabled
        ? "+Wrap"
        : "-Wrap"

    ConsoleOutput := ConsoleGui.AddEdit(
        "x22 y50 w900 r30 ReadOnly -VScroll "
        . WrapOption
        . " Background"
        . SecondaryColor
        . " c"
        . TextColor,
        Text
    )

    ScrollConsoleToBottom()
}

UpdateConsoleWrapAppearance() {
    global ConsoleWrapEnabled
    global ConsoleWrapButton

    global DarkButtonFillOverrides
    global SecondaryBrush

    if DarkButtonFillOverrides.Has(
        ConsoleWrapButton.Hwnd
    )
        DarkButtonFillOverrides.Delete(
            ConsoleWrapButton.Hwnd
        )

    if ConsoleWrapEnabled {
        DarkButtonFillOverrides[
            ConsoleWrapButton.Hwnd
        ] := SecondaryBrush
    }

    RedrawDarkButton(
        ConsoleWrapButton
    )
}

UpdateConsoleLogs(*) {
    global LlamaLog
    global McpLog

    global ConsoleLlamaPosition
    global ConsoleMcpPosition

    global ConsoleLlamaText
    global ConsoleMcpText

    global ConsoleActiveTab


    ; --------------------------------------------------------
    ;  LLAMA
    ; --------------------------------------------------------

    LlamaNew := ReadLogDelta(
        LlamaLog,
        &ConsoleLlamaPosition
    )

    if LlamaNew != "" {
        ConsoleLlamaText .= LlamaNew

        if ConsoleActiveTab = "llama"
            AppendConsoleText(
                LlamaNew
            )
    }


    ; --------------------------------------------------------
    ;  MCP
    ; --------------------------------------------------------

	McpNew := ReadLogDelta(
		McpLog,
		&ConsoleMcpPosition
	)

	McpNew := FilterMcpPolling(
		McpNew
	)

    if McpNew != "" {
        ConsoleMcpText .= McpNew

        if ConsoleActiveTab = "mcp"
            AppendConsoleText(
                McpNew
            )
    }
}

FilterMcpPolling(Text) {
    return RegExReplace(
        Text,
        'm)^INFO:\s+\S+:\d+\s+-\s+"GET /status HTTP/1\.1"\s+200 OK\r?\n?'
    )
}

ReadLogDelta(
    FilePath,
    &Position
) {
    if !FileExist(FilePath)
        return ""

    try {
        File := FileOpen(
            FilePath,
            "r",
            "UTF-8"
        )

        if !IsObject(File)
            return ""


        ; If the logfile was externally truncated or replaced,
        ; start again from its beginning.
        if File.Length < Position
            Position := 0

        File.Pos := Position

        Text := File.Read()

        Position := File.Pos

        File.Close()

        return StripAnsi(
            Text
        )
    }
    catch {
        return ""
    }
}

; ============================================================
;  CONSOLE DISPLAY
; ============================================================

AppendConsoleText(Text) {
    global ConsoleOutput

    static WM_GETTEXTLENGTH := 0x000E
    static EM_SETSEL := 0x00B1
    static EM_REPLACESEL := 0x00C2
    static EM_GETFIRSTVISIBLELINE := 0x00CE
    static EM_LINESCROLL := 0x00B6

    FollowTail := ConsoleIsAtBottom()

    ; Preserve the current viewport if the user has scrolled away.
    if !FollowTail {
        FirstVisibleBefore := DllCall(
            "user32\SendMessageW",
            "ptr", ConsoleOutput.Hwnd,
            "uint", EM_GETFIRSTVISIBLELINE,
            "ptr", 0,
            "ptr", 0
        )
    }

    Length := DllCall(
        "user32\SendMessageW",
        "ptr", ConsoleOutput.Hwnd,
        "uint", WM_GETTEXTLENGTH,
        "ptr", 0,
        "ptr", 0
    )

    DllCall(
        "user32\SendMessageW",
        "ptr", ConsoleOutput.Hwnd,
        "uint", EM_SETSEL,
        "ptr", Length,
        "ptr", Length
    )

    DllCall(
        "user32\SendMessageW",
        "ptr", ConsoleOutput.Hwnd,
        "uint", EM_REPLACESEL,
        "ptr", false,
        "str", Text
    )

    if FollowTail {
        ScrollConsoleToBottom()
        return
    }

    ; EM_SETSEL / EM_REPLACESEL may have scrolled to the caret.
    ; Move the viewport back to the line the user was reading.
    FirstVisibleAfter := DllCall(
        "user32\SendMessageW",
        "ptr", ConsoleOutput.Hwnd,
        "uint", EM_GETFIRSTVISIBLELINE,
        "ptr", 0,
        "ptr", 0
    )

    LineDifference :=
        FirstVisibleBefore
        - FirstVisibleAfter

    if LineDifference {
        DllCall(
            "user32\SendMessageW",
            "ptr", ConsoleOutput.Hwnd,
            "uint", EM_LINESCROLL,
            "ptr", 0,
            "ptr", LineDifference
        )
    }
}

ScrollConsoleToBottom() {
    global ConsoleOutput

    static EM_SCROLL := 0x00B5
    static SB_BOTTOM := 7

    DllCall(
        "user32\SendMessageW",
        "ptr",
        ConsoleOutput.Hwnd,
        "uint",
        EM_SCROLL,
        "ptr",
        SB_BOTTOM,
        "ptr",
        0
    )
}

StripAnsi(Text) {
    ; Standard terminal CSI escape sequences.
    return RegExReplace(
        Text,
        "\x1B\[[0-?]*[ -/]*[@-~]"
    )
}

ConsoleMouseWheel(
    WParam,
    LParam,
    Msg,
    Hwnd
) {
    global ConsoleOutput

    if !IsObject(ConsoleOutput)
        return

    if Hwnd != ConsoleOutput.Hwnd
        return

    static EM_LINESCROLL := 0x00B6

    Delta := (WParam >> 16) & 0xFFFF

    if Delta & 0x8000
        Delta -= 0x10000

    Lines :=
        Delta > 0
        ? -3
        : 3

    DllCall(
        "user32\SendMessageW",
        "ptr", ConsoleOutput.Hwnd,
        "uint", EM_LINESCROLL,
        "ptr", 0,
        "ptr", Lines
    )

    return 0
}

ConsoleIsAtBottom() {
    global ConsoleOutput

    static EM_GETFIRSTVISIBLELINE := 0x00CE
    static EM_GETLINECOUNT := 0x00BA

    FirstVisible := DllCall(
        "user32\SendMessageW",
        "ptr", ConsoleOutput.Hwnd,
        "uint", EM_GETFIRSTVISIBLELINE,
        "ptr", 0,
        "ptr", 0
    )

    LineCount := DllCall(
        "user32\SendMessageW",
        "ptr", ConsoleOutput.Hwnd,
        "uint", EM_GETLINECOUNT,
        "ptr", 0,
        "ptr", 0
    )

    ; Approximate number of visible text rows.
    ConsoleOutput.GetPos(
        ,
        ,
        ,
        &Height
    )

    VisibleLines :=
        Max(
            1,
            Floor(
                Height / 16
            )
        )

    return FirstVisible + VisibleLines >= LineCount - 1
}

; ============================================================
;  CONSOLE REFRESH RATE
; ============================================================

ValidateConsoleRefreshRate(*) {
    global ConsoleRefreshControl
    global ConsoleEffectiveText

    global ConsoleEffectiveRate
    global ConsoleMinRate
    global ConsoleMaxRate


    Requested :=
        Trim(
            ConsoleRefreshControl.Text
        )


    ; User may currently be halfway through editing.
    ; Never modify the field or punish invalid intermediate text.
    if !IsInteger(Requested)
        return


    Requested += 0

    Effective :=
        Max(
            ConsoleMinRate,
            Min(
                Requested,
                ConsoleMaxRate
            )
        )


    ; Nothing materially changed.
    if Effective = ConsoleEffectiveRate
        return


    ConsoleEffectiveRate := Effective

	ConsoleEffectiveText.Text :=
		ConsoleEffectiveRate
		. " ms"


    ; Reconfigure the actual log refresh timer.
    SetTimer(
        UpdateConsoleLogs,
        ConsoleEffectiveRate
    )


    ; Don't make the user wait for the newly selected interval.
    UpdateConsoleLogs()
}

; ============================================================
;  CLOSE CONSOLE VIEWER
; ============================================================

CloseConsoleViewer(*) {
    global ConsoleGui

    global ConsoleLlamaButton
    global ConsoleMcpButton
	global ConsoleWrapButton
	global ConsoleEffectiveRate

    global DarkButtonFillOverrides


    ; Stop both viewer-specific timers.
    SetTimer(
        UpdateConsoleLogs,
        0
    )

    SetTimer(
        ValidateConsoleRefreshRate,
        0
    )
	
	ConfigWrite(
		"State",
		"ConsoleRefreshRate",
		ConsoleEffectiveRate
	)


    ; Remove HWND-specific paint overrides before destroying.
    try {
        if DarkButtonFillOverrides.Has(
            ConsoleLlamaButton.Hwnd
        )
            DarkButtonFillOverrides.Delete(
                ConsoleLlamaButton.Hwnd
            )

        if DarkButtonFillOverrides.Has(
            ConsoleMcpButton.Hwnd
        )
            DarkButtonFillOverrides.Delete(
                ConsoleMcpButton.Hwnd
            )
    }
	
	try {
		if DarkButtonFillOverrides.Has(
			ConsoleWrapButton.Hwnd
		)
			DarkButtonFillOverrides.Delete(
				ConsoleWrapButton.Hwnd
			)
	}


    try ConsoleGui.Destroy()

    ConsoleGui := 0
}

; ============================================================
;  CONTROLLER LIFECYCLE
; ============================================================

ShutdownAll(*) {
    global LlamaState, McpState

    ExternalServices := []

    if LlamaState = "external"
        ExternalServices.Push("Model server")

    if McpState = "external"
        ExternalServices.Push("MCP server")


    if ExternalServices.Length {
        Names := ""

        for Service in ExternalServices {
            if Names != ""
                Names .= "`n"

            Names .= "  • " Service
        }

        Result := MsgBox(
            "The following services are External and will NOT be terminated:`n`n"
            . Names
            . "`n`n"
            . "Shutdown anyway?",
            "Shutdown All",
            "YesNo Icon?"
        )

        if Result != "Yes"
            return
    }

    ExitApp
}

StopProcessTree(Pid) {
    if !Pid
        return

    try RunWait(
        A_ComSpec
        . " /c taskkill /PID "
        . Pid
        . " /T /F",
        ,
        "Hide"
    )
}

; ============================================================
;  LAUNCH
; ============================================================

LaunchAI(ModelKey, ContextOverride, CacheOverride, Directories, ServerKeyOverride := "") {
	global Models
    global McpStartupUntil
    global ActiveMcpConfig, ActiveMcpDirectories
    global ActiveHasLaunched

    Model := Models[ModelKey]

    ServerKey := ServerKeyOverride != "" ? ServerKeyOverride : Model.ServerKey
    Server := GetServer(ServerKey)

	if !Server {
		MsgBox(
			"The model '" Model.Name "' references an unregistered llama server:`n`n"
			. ServerKey,
			"Local AI",
			"Iconx"
		)

		return
	}

    Context :=
        ContextOverride != ""
        ? ContextOverride
        : Model.Context

    Cache :=
        CacheOverride != ""
        ? CacheOverride
        : Model.Cache


    ; --------------------------------------------------------
    ;  VERIFY
    ; --------------------------------------------------------

	if !FileExist(
		Server.Executable
	) {
		MsgBox(
			"Llama server executable not found:`n`n"
			. Server.Executable,
			"Local AI",
			"Iconx"
		)

		return
	}

    if !FileExist(Model.Model) {
        MsgBox(
            "Model not found:`n`n"
            . Model.Model,
            "Local AI",
            "Iconx"
        )

        ReturnToStartup()
        return
    }

    ; --------------------------------------------------------
    ;  MCP
    ; --------------------------------------------------------

    ; MCP is optional. A configuration or startup failure is reported,
    ; but never prevents the selected model from loading.

    DesiredMcp := GetSavedMcpConfig(
        ModelKey
    )

    ActiveMcpConfig := 0
    ActiveMcpDirectories := ""
    McpStartupUntil := 0

    if DesiredMcp.Enabled {
        McpURL := GetMcpStatusURL(
            DesiredMcp
        )

        if HttpStatus(McpURL) != 0 {
            ActiveMcpConfig := CreateMcpRuntimeConfig(
                DesiredMcp,
                true,
                false
            )
        }
        else {
            DesiredMcp.Directories :=
                FilterMcpDirectoriesForLaunch(
                    DesiredMcp.Directories
                )

            if DesiredMcp.Directories = "" {
                if Trim(
                    GetEffectiveMcpDirectories(
                        ModelKey
                    )
                ) = "" {
                    MsgBox(
                        "No MCP directories are configured.`n`nThe model will start without MCP.",
                        "MCP Access",
                        "Icon!"
                    )
                }
            }
            else {
                try {
                    StartMcp(
                        DesiredMcp
                    )

                    if !WaitForHttp(
                        McpURL,
                        10000
                    ) {
                        MsgBox(
                            "MCP was started, but did not become available.`n`nThe model will continue without MCP.",
                            "MCP Access",
                            "Icon!"
                        )
                    }
                }
                catch Error as Err {
                    McpStartupUntil := 0
                    ActiveMcpConfig := 0
                    ActiveMcpDirectories := ""

                    MsgBox(
                        "MCP could not be started:`n`n"
                        . Err.Message
                        . "`n`nThe model will continue without MCP.",
                        "MCP Access",
                        "Icon!"
                    )
                }
            }
        }
    }

    UpdateMcpState()


    ; --------------------------------------------------------
    ;  LLAMA
    ; --------------------------------------------------------

    WebUI :=
		GetServerWebUI(
			Server
		)

	HealthURL :=
		WebUI "/health"
    LlamaStatus := HttpStatus(HealthURL)

    if LlamaStatus = 0 {
		StartLlama(
			ModelKey,
			Context,
			Cache,
            ServerKey
		)

        if !WaitForReady(
            HealthURL,
            120000
        ) {
            MsgBox(
                "llama-server started, but did not become ready.",
                "Local AI",
                "Icon!"
            )
        }
    }

    else if LlamaStatus = 503 {
        WaitForReady(
            HealthURL,
            120000
        )
    }


    ; --------------------------------------------------------
    ;  ACTIVE
    ; --------------------------------------------------------

	ActiveHasLaunched := true

	UpdateActiveState()

	if LlamaPid
	&& ProcessExist(LlamaPid)
	&& HttpStatus(HealthURL) = 200 {
		Run(WebUI)
	}
}


; ============================================================
;  START MCP
; ============================================================

StartMcp(Config) {
    global McpPid
    global McpLog
    global ActiveMcpConfig
    global ActiveMcpDirectories
    global McpStartupUntil, McpStartupGrace

    DirectoryArgs := ""

    for Directory in StrSplit(
        Config.Directories,
        "|"
    ) {
        Directory := Trim(Directory)

        if Directory != ""
            DirectoryArgs .= ' "' Directory '"'
    }

    Host := GetMcpCommandHost(
        Config.Address
    )

    McpCommand :=
        "mcp-proxy "
        . "--host " Host " "
        . "--port " Config.Port " "
        . "--transport streamablehttp "
        . "-- "
        . "mcp-server-filesystem"
        . DirectoryArgs

    Command :=
        A_ComSpec
        . ' /d /s /c "'
        . McpCommand
        . ' >> "'
        . McpLog
        . '" 2>&1"'

    McpStartupUntil :=
        A_TickCount
        + McpStartupGrace

    Run(
        Command,
        A_ScriptDir,
        "Hide",
        &McpPid
    )

    ActiveMcpDirectories := Config.Directories
    ActiveMcpConfig := CreateMcpRuntimeConfig(
        Config
    )
}


; ============================================================
;  START LLAMA
; ============================================================

StartLlama(
    ModelKey,
    Context,
    Cache,
    ServerKey := ""
) {
    global Models

    global LlamaPid
    global LlamaLog

    global LlamaStartupUntil
    global LlamaStartupGrace


    if !Models.Has(ModelKey) {
        MsgBox(
            "Model configuration not found:`n`n"
            . ModelKey,
            "Local AI",
            "Iconx"
        )

        return false
    }

    Model :=
        Models[ModelKey]

    if ServerKey = ""
        ServerKey := Model.ServerKey

    Server := GetServer(ServerKey)


    ; --------------------------------------------------------
    ;  VALIDATE SERVER
    ; --------------------------------------------------------

    if !Server {
	MsgBox(
		"The model '" Model.Name "' references an unregistered llama server:`n`n"
		. ServerKey,
		"Local AI",
		"Iconx"
	)

        return false
    }

    if !FileExist(
        Server.Executable
    ) {
        MsgBox(
            "Llama server executable not found:`n`n"
            . Server.Executable,
            "Local AI",
            "Iconx"
        )

        return false
    }


    ; --------------------------------------------------------
    ;  VALIDATE MODEL
    ; --------------------------------------------------------

    if !FileExist(
        Model.Model
    ) {
        MsgBox(
            "Model not found:`n`n"
            . Model.Model,
            "Local AI",
            "Iconx"
        )

        return false
    }


    ; --------------------------------------------------------
    ;  BUILD COMMAND
    ; --------------------------------------------------------

    LlamaStartupUntil :=
        A_TickCount
        + LlamaStartupGrace

    ServerCommand :=
        '"'
        . Server.Executable
        . '" '
        . '-m "'
        . Model.Model
        . '" '
        . '-ngl 99 '
        . '-c '
        . Context
        . ' '
        . '-np 1 '
        . '--cache-type-k '
        . Cache
        . ' '
        . '--cache-type-v '
        . Cache
        . ' '


    ; Server-wide arguments apply to every model using it.
    if Server.Args != ""
        ServerCommand .=
            Server.Args
            . " "


    ; Model arguments apply only to this model.
    if Model.Args != ""
        ServerCommand .=
            Model.Args
            . " "


    ; Registered address and port remain authoritative.
    ServerCommand .=
        '--host '
        . Server.Address
        . ' '
        . '--port '
        . Server.Port


    ; --------------------------------------------------------
    ;  LAUNCH
    ; --------------------------------------------------------

    Command :=
        A_ComSpec
        . ' /d /s /c "'
        . ServerCommand
        . ' >> "'
        . LlamaLog
        . '" 2>&1"'

    Run(
        Command,
        GetParentDirectory(
            Server.Executable
        ),
        "Hide",
        &LlamaPid
    )

    SaveLastModel(
        ModelKey
    )

    return true
}


; ============================================================
;  LOAD MODEL CONFIGURATION
; ============================================================

LoadModels() {
    global ModelList

    Models := Map()

    for Key in ModelList {
        Models[Key] := {
            Name: ConfigRead(
                Key,
                "Name",
                Key
            ),

            ServerKey: ConfigRead(
                Key,
                "Server",
                ""
            ),

            Model: ConfigRead(
                Key,
                "Model",
                ""
            ),

            Context: ConfigReadInteger(
                Key,
                "Context",
                32768
            ),

            Cache: ConfigRead(
                Key,
                "Cache",
                "q4_0"
            ),

            Args: ConfigRead(
                Key,
                "Args",
                ""
            ),

            McpDirectories: ConfigRead(
                Key,
                "McpDirectories",
                ""
            )
        }
    }

    return Models
}

; ============================================================
;  ACTIVE STATUS
; ============================================================

UpdateActiveState(*) {
    global ControllerMode
    global ActiveHasLaunched
    global FastPollRate, IdlePollRate

    if ControllerMode != "active"
        return

    LlamaStable := UpdateLlamaState()
    McpStable := UpdateMcpState()

    if LlamaStable && McpStable
        SetActivePollRate(IdlePollRate)
    else
        SetActivePollRate(FastPollRate)
}


UpdateLlamaState() {
    global LlamaPid

    global ActiveModelKey
    global ActiveServerKey
    global ActiveContext
    global ActiveCache

    global Models

    global ActiveLlamaStatus
    global ActiveLlamaName
    global ActiveLlamaDetails

    global ActiveLlamaEditButton
    global ActiveLlamaStartButton
    global ActiveLlamaRestartButton
    global ActiveLlamaStopButton

    global LlamaStartupUntil
    global LlamaState


    if LlamaPid
    && !ProcessExist(LlamaPid)
        LlamaPid := 0


    if !Models.Has(
        ActiveModelKey
    )
        return true


    Model :=
        Models[ActiveModelKey]

    Server := GetServer(
        ActiveServerKey
    )


    ; --------------------------------------------------------
    ;  INVALID SERVER REFERENCE
    ; --------------------------------------------------------

    if !Server {
        LlamaStartupUntil := 0
        LlamaState := "offline"

        ActiveLlamaStatus.Text :=
            "○ Offline"

        ActiveLlamaName.Text :=
            Model.Name

        ActiveLlamaDetails.Text :=
            "Server not registered: "
            . ActiveServerKey

        ActiveLlamaEditButton.Enabled := true
        ActiveLlamaStartButton.Enabled := true
        ActiveLlamaRestartButton.Enabled := false

        ; We can still terminate an owned process by PID.
        ActiveLlamaStopButton.Enabled :=
            LlamaPid
            && ProcessExist(LlamaPid)

        return true
    }


    WebUI :=
        GetServerWebUI(
            Server
        )

    HealthURL :=
        WebUI "/health"

    Owned :=
        LlamaPid
        && ProcessExist(LlamaPid)

    Status :=
        HttpStatus(
            HealthURL
        )


    if Status = 200
        LlamaStartupUntil := 0


    ; --------------------------------------------------------
    ;  OFFLINE
    ; --------------------------------------------------------

    if Status = 0 {
        if A_TickCount
        < LlamaStartupUntil {
            LlamaState := "loading"

            ActiveLlamaStatus.Text :=
                "◐ Loading"

            ActiveLlamaStartButton.Enabled := false
            ActiveLlamaRestartButton.Enabled := false
            ActiveLlamaStopButton.Enabled := true

            return false
        }

        LlamaStartupUntil := 0
        LlamaState := "offline"

        ActiveLlamaStatus.Text :=
            "○ Offline"

        ActiveLlamaName.Text :=
            Model.Name

        ActiveLlamaDetails.Text :=
            ActiveContext
            . " context  •  "
            . ActiveCache
            . " KV  •  "
            . Server.Name
            . " : "
            . Server.Port

        ActiveLlamaEditButton.Enabled := true
        ActiveLlamaStartButton.Enabled := true
        ActiveLlamaRestartButton.Enabled := false
        ActiveLlamaStopButton.Enabled := false

        return true
    }


    ; --------------------------------------------------------
    ;  EXTERNAL
    ; --------------------------------------------------------

    if !Owned {
        LlamaState := "external"

        if Status = 503
            ActiveLlamaStatus.Text :=
                "◐ External"
        else
            ActiveLlamaStatus.Text :=
                "● External"

        ActiveLlamaName.Text :=
            "Existing llama-server"

        ActiveLlamaDetails.Text :=
            Server.Name
            . "  •  Port "
            . Server.Port
            . "  •  Not owned by controller"

        ActiveLlamaEditButton.Enabled := false
        ActiveLlamaStartButton.Enabled := false
        ActiveLlamaRestartButton.Enabled := false
        ActiveLlamaStopButton.Enabled := true

        return Status != 503
    }


    ; --------------------------------------------------------
    ;  OWNED
    ; --------------------------------------------------------

    ActiveLlamaName.Text :=
        Model.Name

    ActiveLlamaDetails.Text :=
        ActiveContext
        . " context  •  "
        . ActiveCache
        . " KV  •  "
        . Server.Name
        . " : "
        . Server.Port


    if Status = 503 {
        LlamaState := "loading"

        ActiveLlamaStatus.Text :=
            "◐ Loading"

        ActiveLlamaEditButton.Enabled := false
        ActiveLlamaStartButton.Enabled := false
        ActiveLlamaRestartButton.Enabled := false
        ActiveLlamaStopButton.Enabled := true

        return false
    }

    else if Status = 200 {
        LlamaState := "online"

        ActiveLlamaStatus.Text :=
            "● Online"

        ActiveLlamaEditButton.Enabled := true
        ActiveLlamaStartButton.Enabled := false
        ActiveLlamaRestartButton.Enabled := true
        ActiveLlamaStopButton.Enabled := true

        return true
    }

    else {
        LlamaState := "error"

        ActiveLlamaStatus.Text :=
            "! HTTP "
            . Status

        ActiveLlamaStartButton.Enabled := false
        ActiveLlamaRestartButton.Enabled := true
        ActiveLlamaStopButton.Enabled := true

        return false
    }
}


UpdateMcpState() {
    global McpPid
    global ActiveModelKey
    global ActiveMcpConfig
    global ActiveMcpDirectories

    global ActiveMcpStatus
    global ActiveMcpName
    global ActiveMcpDetails

    global ActiveMcpEditButton
    global ActiveMcpStartButton
    global ActiveMcpRestartButton
    global ActiveMcpStopButton

    global McpStartupUntil
    global McpState


    if McpPid
    && !ProcessExist(McpPid) {
        McpPid := 0

        if IsObject(ActiveMcpConfig)
        && !ActiveMcpConfig.External {
            ActiveMcpConfig := 0
            ActiveMcpDirectories := ""
        }
    }

    Owned :=
        McpPid
        && ProcessExist(McpPid)

    Desired := GetSavedMcpConfig(
        ActiveModelKey
    )


    ; --------------------------------------------------------
    ;  DISABLED
    ; --------------------------------------------------------

    if !IsObject(ActiveMcpConfig)
    && !Desired.Enabled {
        McpStartupUntil := 0
        McpState := "disabled"
        ActiveMcpStatus.Text := "○ Disabled"
        ActiveMcpName.Text := "Disabled"
        ActiveMcpDetails.Text := ""

        ActiveMcpEditButton.Enabled := true
        ActiveMcpStartButton.Enabled := false
        ActiveMcpRestartButton.Enabled := false
        ActiveMcpStopButton.Enabled := false

        return true
    }

    Runtime := IsObject(ActiveMcpConfig)
        ? ActiveMcpConfig
        : Desired

    Status := HttpStatus(
        GetMcpStatusURL(
            Runtime
        )
    )

    if Status != 0
        McpStartupUntil := 0


    ; --------------------------------------------------------
    ;  OFFLINE / LOADING
    ; --------------------------------------------------------

    if Status = 0 {
        if A_TickCount < McpStartupUntil {
            McpState := "loading"
            ActiveMcpStatus.Text := "◐ Loading"
            ActiveMcpName.Text := "Filesystem"

            ActiveMcpEditButton.Enabled := false
            ActiveMcpStartButton.Enabled := false
            ActiveMcpRestartButton.Enabled := false
            ActiveMcpStopButton.Enabled := Owned

            return false
        }

        McpStartupUntil := 0

        ; If an external/runtime snapshot has disappeared, release it.
        ; The next pass should reflect whatever is currently saved.
        if IsObject(ActiveMcpConfig)
        && !Owned {
            ActiveMcpConfig := 0
            ActiveMcpDirectories := ""
            return UpdateMcpState()
        }

        McpState := Owned
            ? "error"
            : "offline"

        ActiveMcpStatus.Text := Owned
            ? "! Offline"
            : "○ Offline"

        ActiveMcpName.Text := "Filesystem"

        Details := DisplayDirectories(
            Owned
                ? ActiveMcpDirectories
                : Desired.Directories
        )

        if Owned {
            Difference := GetMcpConfigDifferenceState()

            if Difference = "pending"
                Details := PrependMcpDetail(
                    Details,
                    "Changes pending"
                )
            else if Difference = "stale"
                Details := PrependMcpDetail(
                    Details,
                    "Unavailable paths omitted"
                )
        }

        ActiveMcpDetails.Text := Details

        ActiveMcpEditButton.Enabled := true
        ActiveMcpStartButton.Enabled := !Owned
        ActiveMcpRestartButton.Enabled := Owned
        ActiveMcpStopButton.Enabled := Owned

        return true
    }


    ; --------------------------------------------------------
    ;  EXTERNAL PROXY
    ; --------------------------------------------------------

    if !Owned {
        if !IsObject(ActiveMcpConfig)
        || !ActiveMcpConfig.External {
            ActiveMcpConfig := CreateMcpRuntimeConfig(
                Runtime,
                true,
                false
            )

            ActiveMcpDirectories := ""
        }

        McpState := "external"
        ActiveMcpStatus.Text := "● External"
        ActiveMcpName.Text := "Existing MCP proxy"

        Details :=
            GetMcpEndpointLabel(
                ActiveMcpConfig
            )
            . "  •  Access configuration unknown"

        if GetMcpConfigDifferenceState() = "pending"
            Details := PrependMcpDetail(
                Details,
                "Changes pending"
            )

        ActiveMcpDetails.Text := Details

        ActiveMcpEditButton.Enabled := true
        ActiveMcpStartButton.Enabled := false
        ActiveMcpRestartButton.Enabled := false
        ActiveMcpStopButton.Enabled := true

        return true
    }


    ; --------------------------------------------------------
    ;  OWNED PROXY
    ; --------------------------------------------------------

    McpState := "online"
    ActiveMcpStatus.Text := "● Online"
    ActiveMcpName.Text := "Filesystem"

    Details := DisplayDirectories(
        ActiveMcpDirectories
    )

    Difference := GetMcpConfigDifferenceState()

    if Difference = "pending"
        Details := PrependMcpDetail(
            Details,
            "Changes pending"
        )
    else if Difference = "stale"
        Details := PrependMcpDetail(
            Details,
            "Unavailable paths omitted"
        )

    ActiveMcpDetails.Text := Details

    ActiveMcpEditButton.Enabled := true
    ActiveMcpStartButton.Enabled := false
    ActiveMcpRestartButton.Enabled := true
    ActiveMcpStopButton.Enabled := true

    return true
}

EnterActiveView(ModelKey, Context, Cache, Directories, ServerKey := "") {
    global ControllerMode
    global ActiveHasLaunched

    global ActiveModelKey
    global ActiveServerKey
    global ActiveContext
    global ActiveCache
    global ActiveMcpDirectories
    global ActiveMcpConfig

    global MainGui, ActiveGui
    global ModelList, Models

    global ActiveLlamaStatus
    global ActiveLlamaName
    global ActiveLlamaDetails

    global ActiveMcpStatus
    global ActiveMcpName
    global ActiveMcpDetails

    global ActiveLlamaEditButton
    global ActiveLlamaStartButton
    global ActiveLlamaRestartButton
    global ActiveLlamaStopButton

    global ActiveMcpEditButton
    global ActiveMcpStartButton
    global ActiveMcpRestartButton
    global ActiveMcpStopButton

    global LlamaState, McpState
    global LlamaStartupUntil, LlamaStartupGrace
    global McpStartupUntil, McpStartupGrace

    ActiveModelKey := ModelKey
    ActiveServerKey := ServerKey != "" ? ServerKey : Models[ModelKey].ServerKey
    ActiveContext := Context
    ActiveCache := Cache

    ActiveMcpConfig := 0
    ActiveMcpDirectories := ""

    ActiveLlamaEditButton.Enabled := false

    ControllerMode := "active"
    ActiveHasLaunched := false

    LlamaStartupUntil :=
        A_TickCount
        + LlamaStartupGrace

    LlamaState := "loading"
    ActiveLlamaStatus.Text := "◐ Loading"


    ; Keep the startup selector synchronized with
    ; whatever model actually entered Active mode.

    for Index, Key in ModelList {
        if Key = ModelKey {
            SyncMainModelSelection(ModelKey)
            break
        }
    }

    UpdateMainModelInfo()


    ; Immediate visual feedback before processes appear.

    Model := Models[ModelKey]
    DesiredMcp := GetSavedMcpConfig(ModelKey)

    ActiveLlamaStatus.Text := "◐ Starting"
    ActiveLlamaName.Text := Model.Name

    ActiveLlamaDetails.Text :=
        Context
        . " context  •  "
        . Cache
        . " KV"

    if !DesiredMcp.Enabled {
        McpStartupUntil := 0
        McpState := "disabled"
        ActiveMcpStatus.Text := "○ Disabled"
        ActiveMcpName.Text := "Disabled"
        ActiveMcpDetails.Text := ""
    }
    else {
        McpStartupUntil :=
            A_TickCount
            + McpStartupGrace

        McpState := "loading"
        ActiveMcpStatus.Text := "◐ Starting"
        ActiveMcpName.Text := "Filesystem"
        ActiveMcpDetails.Text := DisplayDirectories(
            DesiredMcp.Directories
        )
    }


    ; Don't offer process controls during the handoff.

    ActiveLlamaStartButton.Enabled := false
    ActiveLlamaRestartButton.Enabled := false
    ActiveLlamaStopButton.Enabled := false

    ActiveMcpEditButton.Enabled := false
    ActiveMcpStartButton.Enabled := false
    ActiveMcpRestartButton.Enabled := false
    ActiveMcpStopButton.Enabled := false


    ShowRelative(
        ActiveGui,
        MainGui
    )

    MainGui.Hide()

    ; Begin one-second live polling.

    SetActivePollRate(1000)

    ; Give Windows a chance to paint Active before
    ; LaunchAI begins waiting on the services.

    Sleep(50)
}

; ============================================================
;  ACTIVE LLAMA CONTROLS
; ============================================================

StartActiveLlama(*) {
    global ActiveModelKey
    global ActiveServerKey
    global ActiveContext
    global ActiveCache

    global ActiveLlamaStatus
    global ActiveLlamaStartButton
    global ActiveLlamaRestartButton
    global ActiveLlamaStopButton

    global FastPollRate


    SetActivePollRate(
        FastPollRate
    )

    ActiveLlamaStatus.Text :=
        "◐ Starting"

    ActiveLlamaStartButton.Enabled := false
    ActiveLlamaRestartButton.Enabled := false
    ActiveLlamaStopButton.Enabled := false

    StartLlama(
        ActiveModelKey,
        ActiveContext,
        ActiveCache,
        ActiveServerKey
    )
}

RestartLlamaWithOfflineURL(
    OfflineURL := ""
) {
    global LlamaPid
    global ActiveLlamaStatus
    global FastPollRate


    SetActivePollRate(
        FastPollRate
    )

    if !LlamaPid
        return

    ActiveLlamaStatus.Text :=
        "◐ Restarting"

    StopProcessTree(
        LlamaPid
    )

    LlamaPid := 0

    if OfflineURL != "" {
        WaitForOffline(
            OfflineURL,
            10000
        )
    }

    StartActiveLlama()
}

RestartActiveLlama(*) {
    global ActiveModelKey, ActiveServerKey

    RestartLlamaWithOfflineURL(
        GetModelHealthURL(
            ActiveModelKey,
            ActiveServerKey
        )
    )
}


StopActiveLlama(*) {
    global LlamaPid
    global ActiveModelKey, ActiveServerKey

    global ActiveLlamaStatus
    global FastPollRate


    SetActivePollRate(
        FastPollRate
    )

    Server := GetServer(
        ActiveServerKey
    )


    ; --------------------------------------------------------
    ;  OWNED
    ; --------------------------------------------------------

    if LlamaPid
    && ProcessExist(LlamaPid) {
        HealthURL :=
            Server
                ? GetServerWebUI(Server) "/health"
                : ""

        ActiveLlamaStatus.Text :=
            "◐ Stopping"

        StopProcessTree(
            LlamaPid
        )

        LlamaPid := 0

        if HealthURL != "" {
            WaitForOffline(
                HealthURL,
                10000
            )
        }

        UpdateActiveState()
        return
    }


    ; --------------------------------------------------------
    ;  EXTERNAL
    ; --------------------------------------------------------

    if !Server {
        MsgBox(
            "The active model does not reference a registered llama server.",
            "Local AI",
            "Icon!"
        )

        return
    }

    HealthURL :=
        GetServerWebUI(
            Server
        )
        . "/health"

    if HttpStatus(
        HealthURL
    ) = 0
        return


    Result := MsgBox(
        "This llama-server was not started by the controller.`n`n"
        . "Terminate the process listening on port "
        . Server.Port
        . "?",
        "Terminate External Model",
        "YesNo Icon?"
    )

    if Result != "Yes"
        return


    ExternalPid :=
        GetListeningPid(
            Server.Port
        )

    if !ExternalPid {
        MsgBox(
            "The process using port "
            . Server.Port
            . " could not be identified.",
            "Local AI",
            "Icon!"
        )

        return
    }

    ActiveLlamaStatus.Text :=
        "◐ Stopping"

    StopProcessTree(
        ExternalPid
    )

    WaitForOffline(
        HealthURL,
        10000
    )

    UpdateActiveState()
}

; ============================================================
;  ACTIVE MCP CONTROLS
; ============================================================

StartActiveMcp(*) {
    global ActiveModelKey
    global ActiveMcpDirectories
    global ActiveMcpConfig
    global ActiveMcpStatus
    global McpStartupUntil, McpStartupGrace
    global FastPollRate

    SetActivePollRate(FastPollRate)

    Desired := GetSavedMcpConfig(
        ActiveModelKey
    )

    if !Desired.Enabled {
        McpStartupUntil := 0
        ActiveMcpConfig := 0
        ActiveMcpDirectories := ""
        UpdateActiveState()
        return
    }

    if HttpStatus(
        GetMcpStatusURL(
            Desired
        )
    ) != 0 {
        ActiveMcpConfig := CreateMcpRuntimeConfig(
            Desired,
            true,
            false
        )

        ActiveMcpDirectories := ""
        UpdateActiveState()
        return
    }

    Desired.Directories :=
        FilterMcpDirectoriesForLaunch(
            Desired.Directories
        )

    if Desired.Directories = "" {
        if Trim(
            GetEffectiveMcpDirectories(
                ActiveModelKey
            )
        ) = "" {
            MsgBox(
                "No MCP directories are configured.`n`nMCP will stay Offline.",
                "MCP Access",
                "Icon!"
            )
        }

        McpStartupUntil := 0
        ActiveMcpConfig := 0
        ActiveMcpDirectories := ""
        UpdateActiveState()
        return
    }

    McpStartupUntil :=
        A_TickCount
        + McpStartupGrace

    ActiveMcpStatus.Text := "◐ Starting"

    try StartMcp(
        Desired
    )
    catch Error as Err {
        McpStartupUntil := 0
        ActiveMcpConfig := 0
        ActiveMcpDirectories := ""

        MsgBox(
            "MCP could not be started:`n`n"
            . Err.Message,
            "MCP Access",
            "Icon!"
        )

        UpdateActiveState()
    }
}


RestartActiveMcp(*) {
    global McpState

    if McpState = "external"
        return

    ApplySavedMcpConfiguration()
}


StopActiveMcp(*) {
    global McpPid
    global ActiveMcpConfig
    global ActiveMcpDirectories
    global ActiveMcpStatus
    global McpStartupUntil
    global FastPollRate

    SetActivePollRate(FastPollRate)

    if !IsObject(ActiveMcpConfig) {
        UpdateActiveState()
        return
    }

    RuntimeConfig := ActiveMcpConfig
    StatusURL := GetMcpStatusURL(
        RuntimeConfig
    )

    if HttpStatus(StatusURL) = 0 {
        ActiveMcpConfig := 0
        ActiveMcpDirectories := ""
        McpStartupUntil := 0
        UpdateActiveState()
        return
    }


    ; --------------------------------------------------------
    ;  OWNED
    ; --------------------------------------------------------

    if McpPid && ProcessExist(McpPid) {
        ActiveMcpStatus.Text := "◐ Stopping"

        StopProcessTree(McpPid)
        McpPid := 0
    }


    ; --------------------------------------------------------
    ;  EXTERNAL MCP-PROXY
    ; --------------------------------------------------------

    else {
        Result := MsgBox(
            "This MCP proxy was not started by the controller.`n`n"
            . "Terminate the process listening on port "
            . RuntimeConfig.Port
            . "?",
            "Terminate External MCP",
            "YesNo Icon?"
        )

        if Result != "Yes"
            return

        ExternalPid := GetListeningPid(
            RuntimeConfig.Port
        )

        if !ExternalPid {
            MsgBox(
                "The process using port "
                . RuntimeConfig.Port
                . " could not be identified.",
                "Local AI",
                "Icon!"
            )

            return
        }

        ActiveMcpStatus.Text := "◐ Stopping"

        StopProcessTree(
            ExternalPid
        )
    }

    WaitForOffline(
        StatusURL,
        10000
    )

    ActiveMcpConfig := 0
    ActiveMcpDirectories := ""
    McpStartupUntil := 0
    UpdateActiveState()
}

; ============================================================
;  CONFIG DIALOG MANAGEMENT
; ============================================================

BeginConfigDialog(DialogGui, ParentGui) {
    global ActiveConfigDialog

    ; Another configuration dialog already exists.
    if IsObject(ActiveConfigDialog) {
        try {
            ActiveConfigDialog.Show()
            WinActivate("ahk_id " ActiveConfigDialog.Hwnd)
            return false
        }
        catch {
            ActiveConfigDialog := 0
        }
    }

    ActiveConfigDialog := DialogGui

    ; Native owned-window relationship:
    ; child stays above its parent.
    DialogGui.Opt(
        "+Owner" ParentGui.Hwnd
        . " -MinimizeBox -MaximizeBox"
    )

    ; Modal behavior.
    ParentGui.Opt("+Disabled")

    return true
}


EndConfigDialog(
    DialogGui,
    ParentGui,
    ShowParent := true
) {
    global ActiveConfigDialog

    try DialogGui.Destroy()

    ActiveConfigDialog := 0

    ParentGui.Opt("-Disabled")

    if ShowParent {
        ParentGui.Show()

        try WinActivate(
            "ahk_id " ParentGui.Hwnd
        )
    }
}


RaiseConfigDialog() {
    global ActiveConfigDialog

    if !IsObject(ActiveConfigDialog)
        return

    try {
        ActiveConfigDialog.Show()

        WinActivate(
            "ahk_id " ActiveConfigDialog.Hwnd
        )
    }
}

; ============================================================
;  OFFLINE / STARTUP HELPERS
; ============================================================

WaitForOffline(URL, TimeoutMs) {
    StartTime := A_TickCount

    while A_TickCount - StartTime < TimeoutMs {
        if HttpStatus(URL, 100) = 0
            return true

        Sleep(100)
    }

    return false
}

ReturnToStartup() {
    global ControllerMode
    global ActiveHasLaunched
    global ActiveGui, MainGui
	global ActivePollRate

    ControllerMode := "start"
    ActiveHasLaunched := false

	SetTimer(
		UpdateActiveState,
		0
	)

	ActivePollRate := 0

	ShowRelative(
		MainGui,
		ActiveGui
	)

	ActiveGui.Hide()
}

; ============================================================
;  MCP CONFIGURATION HELPERS
; ============================================================

GetEffectiveMcpDirectories(ModelKey := "") {
    global McpDirectories
    global Models

    ModelDirectories := ""

    if ModelKey != ""
    && Models.Has(ModelKey)
        ModelDirectories := Models[ModelKey].McpDirectories

    return MergeMcpDirectories(
        McpDirectories,
        ModelDirectories
    )
}


MergeMcpDirectories(DirectorySets*) {
    Output := ""
    Seen := Map()

    for Directories in DirectorySets {
        for Directory in StrSplit(
            Directories,
            "|"
        ) {
            Directory := Trim(Directory)

            if Directory = ""
                continue

            Key := NormalizeDirectoryKey(
                Directory
            )

            if Seen.Has(Key)
                continue

            Seen[Key] := true

            if Output != ""
                Output .= "|"

            Output .= Directory
        }
    }

    return Output
}


GetSavedMcpConfig(ModelKey := "") {
    global McpEnabled, McpAddress, McpPort

    return {
        Enabled: McpEnabled,
        Address: Trim(McpAddress),
        Port: McpPort + 0,
        Directories: GetEffectiveMcpDirectories(
            ModelKey
        )
    }
}


CreateMcpRuntimeConfig(Config, External := false, AccessKnown := true) {
    return {
        Enabled: Config.Enabled,
        Address: Trim(Config.Address),
        Port: Config.Port + 0,
        Directories: Config.Directories,
        External: External,
        AccessKnown: AccessKnown
    }
}


McpCoreConfigsMatch(A, B) {
    if !IsObject(A) || !IsObject(B)
        return false

    if A.Enabled != B.Enabled
        return false

    if StrLower(Trim(A.Address)) != StrLower(Trim(B.Address))
        return false

    return A.Port + 0 = B.Port + 0
}


McpEndpointsMatch(A, B) {
    if !IsObject(A) || !IsObject(B)
        return false

    if StrLower(Trim(A.Address)) != StrLower(Trim(B.Address))
        return false

    return A.Port + 0 = B.Port + 0
}


McpConfigsMatch(A, B) {
    if !McpCoreConfigsMatch(A, B)
        return false

    return SameDirectories(
        A.Directories,
        B.Directories
    )
}


GetMcpConfigDifferenceState() {
    global ActiveMcpConfig
    global ActiveModelKey

    if !IsObject(ActiveMcpConfig)
        return ""

    Desired := GetSavedMcpConfig(
        ActiveModelKey
    )

    if McpConfigsMatch(
        ActiveMcpConfig,
        Desired
    )
        return ""

    if !McpCoreConfigsMatch(
        ActiveMcpConfig,
        Desired
    )
        return "pending"

    if !ActiveMcpConfig.AccessKnown
        return "pending"

    FilteredDesired :=
        FilterMcpDirectoriesForLaunch(
            Desired.Directories,
            false
        )

    return SameDirectories(
        ActiveMcpConfig.Directories,
        FilteredDesired
    )
        ? "stale"
        : "pending"
}


GetMcpBaseURL(Config) {
    Host := GetMcpCommandHost(
        Config.Address
    )

    if Host = "0.0.0.0"
        Host := "127.0.0.1"
    else if Host = "::" || Host = "[::]"
        Host := "[::1]"

    return "http://"
        . Host
        . ":"
        . Config.Port
}


GetMcpStatusURL(Config) {
    return GetMcpBaseURL(
        Config
    )
        . "/status"
}


GetMcpEndpointLabel(Config) {
    Host := GetMcpCommandHost(
        Config.Address
    )

    return Host
        . ":"
        . Config.Port
}


GetMcpCommandHost(Address) {
    Host := RegExReplace(
        Trim(Address),
        "i)^https?://"
    )

    return RTrim(
        Host,
        "/"
    )
}

PrependMcpDetail(Details, Notice) {
    return Details != ""
        ? Notice "`n" Details
        : Notice
}


FilterMcpDirectoriesForLaunch(Directories, Notify := true) {
    Valid := ""
    Missing := []

    Directories := MergeMcpDirectories(
        Directories
    )

    for Directory in StrSplit(Directories, "|") {
        Directory := Trim(Directory)

        if Directory = ""
            continue

        if DirExist(Directory) {
            if Valid != ""
                Valid .= "|"

            Valid .= Directory
        }
        else
            Missing.Push(Directory)
    }

    if Notify && Missing.Length {
        MissingText := ""

        for Directory in Missing {
            if MissingText != ""
                MissingText .= "`n"

            MissingText .= "  • " Directory
        }

        Message :=
            "The following MCP directories were not found and will be omitted from this start:`n`n"
            . MissingText

        if Valid = ""
            Message .= "`n`nNo valid directories remain. MCP will stay Offline."

        MsgBox(
            Message,
            "MCP Access",
            "Icon!"
        )
    }

    return Valid
}


; ============================================================
;  DIRECTORY HELPERS
; ============================================================

ResolvePath(Path) {
    Path := Trim(Path)

    ; Drive-qualified or UNC path: already absolute.
    if RegExMatch(
        Path,
        "i)^[A-Z]:\\|^\\\\"
    )
        return Path

    ; Otherwise relative to the controller itself.
    return A_ScriptDir "\" Path
}

VerifyDirectories(Directories) {
    FoundDirectory := false

    for Directory in StrSplit(Directories, "|") {
        Directory := Trim(Directory)

        if Directory = ""
            continue

        FoundDirectory := true

        if !DirExist(Directory) {
            MsgBox(
                "MCP directory not found:`n`n"
                . Directory,
                "Local AI",
                "Iconx"
            )

            return false
        }
    }

    return FoundDirectory
}

NormalizeDirectoryKey(Directory) {
    Directory := Trim(Directory)

    if StrLen(Directory) > 3
        Directory := RTrim(
            Directory,
            "\\/"
        )

    return StrLower(Directory)
}


DirectorySet(Directories) {
    Set := Map()

    for Directory in StrSplit(
        Directories,
        "|"
    ) {
        Directory := Trim(Directory)

        if Directory = ""
            continue

        Set[
            NormalizeDirectoryKey(
                Directory
            )
        ] := true
    }

    return Set
}


SameDirectories(A, B) {
    ASet := DirectorySet(A)
    BSet := DirectorySet(B)

    if ASet.Count != BSet.Count
        return false

    for Key in ASet {
        if !BSet.Has(Key)
            return false
    }

    return true
}

DisplayDirectories(Directories) {
    Output := ""

    for Directory in StrSplit(Directories, "|") {
        Directory := Trim(Directory)

        if Directory = ""
            continue

        if Output != ""
            Output .= "`n"

        Output .= Directory
    }

    return Output
}


DirectoriesForEdit(Directories) {
    return StrReplace(
        Directories,
        "|",
        "`r`n"
    )
}


DirectoriesFromEdit(Text) {
    Text := StrReplace(
        Text,
        "`r",
        ""
    )

    Lines := StrSplit(
        Text,
        "`n"
    )

    Output := ""

    for Line in Lines {
        Directory := Trim(Line)

        if Directory = ""
            continue

        if Output != ""
            Output .= "|"

        Output .= Directory
    }

    return Output
}


GetParentDirectory(FilePath) {
    SplitPath(
        FilePath,
        ,
        &Directory
    )

    return Directory
}

; ============================================================
;  DROPDOWN HELPERS
; ============================================================

ChooseCache(Control, Cache) {
    switch Cache {
        case "f16":
            Control.Choose(1)

        case "q8_0":
            Control.Choose(2)

        case "q4_0":
            Control.Choose(3)

        default:
            Control.Choose(3)
    }
}


; ============================================================
;  HTTP HELPERS
; ============================================================

HttpStatus(URL, Timeout := 500) {
    try {
        Request := ComObject(
            "WinHttp.WinHttpRequest.5.1"
        )

        Request.SetTimeouts(
            Timeout,
            Timeout,
            Timeout,
            Timeout
        )

        Request.Open(
            "GET",
            URL,
            false
        )

        Request.Send()

        return Request.Status
    }
    catch {
        return 0
    }
}


WaitForHttp(URL, TimeoutMs) {
    StartTime := A_TickCount

    while A_TickCount - StartTime < TimeoutMs {
        if HttpStatus(URL) != 0
            return true

        Sleep(250)
    }

    return false
}


WaitForReady(URL, TimeoutMs) {
    StartTime := A_TickCount

    while A_TickCount - StartTime < TimeoutMs {
        if HttpStatus(URL) = 200
            return true

        Sleep(250)
    }

    return false
}

; ============================================================
;  LLAMA SERVER MANAGEMENT UI
; ============================================================

OpenServerManager(ParentGui, SelectedServerKey := "", OnChanged := 0) {
    global ServerManagerState
    global BaseColor, TextColor, MutedColor

    if IsObject(ServerManagerState) {
        try {
            ServerManagerState.Gui.Show()
            WinActivate("ahk_id " ServerManagerState.Gui.Hwnd)
            return
        }
        catch
            ServerManagerState := 0
    }

    ManagerGui := Gui(, "Llama Servers")
    ManagerGui.Opt("+Owner" ParentGui.Hwnd " -MinimizeBox -MaximizeBox")
    ParentGui.Opt("+Disabled")
    ManagerGui.BackColor := BaseColor
    ManagerGui.MarginX := 24
    ManagerGui.MarginY := 20
    ApplyDarkWindow(ManagerGui)

    ManagerGui.SetFont("s14 Bold c" TextColor, "Segoe UI")
    ManagerGui.AddText("xm w480 Center", "LLAMA SERVERS")

    ManagerGui.SetFont("s12 Norm c" TextColor, "Segoe UI")
    ManagerGui.AddText("x24 y70", "Registered server")
    ServerControl := ManagerGui.AddDropDownList("x24 y99 w382 +0x210", [])
    ApplyDarkControl(ServerControl)

    ManagerGui.SetFont("s11 c" TextColor, "Segoe UI")
    EditButton := ManagerGui.AddButton("x414 y98 w26 h26", "…")
    AddButton := ManagerGui.AddButton("x446 yp w26 h26", "+")

    ManagerGui.SetFont("s13 c" TextColor, "Segoe UI")
    DeleteButton := ManagerGui.AddButton("x478 yp w26 h26", "×")

    MakeOwnerDrawButton(EditButton)
    MakeOwnerDrawButton(AddButton)
    MakeOwnerDrawButton(DeleteButton)

    ManagerGui.SetFont("s10 c" MutedColor, "Segoe UI")
    SummaryText := ManagerGui.AddText("x24 y143 w480 h50", "")

    ServerManagerState := {
        Gui: ManagerGui, Parent: ParentGui, ServerControl: ServerControl, ServerKeys: [],
        SummaryText: SummaryText, EditButton: EditButton, DeleteButton: DeleteButton,
        OnChanged: OnChanged
    }

    ServerControl.OnEvent("Change", UpdateServerManagerDetails)
    EditButton.OnEvent("Click", EditSelectedServer)
    AddButton.OnEvent("Click", (*) => OpenServerEditor(ManagerGui))
    DeleteButton.OnEvent("Click", DeleteSelectedServer)
    ManagerGui.OnEvent("Close", CloseServerManager)

    RefreshServerManager(SelectedServerKey)
    ShowRelative(ManagerGui, ParentGui)
}


CloseServerManager(*) {
    global ServerManagerState

    if !IsObject(ServerManagerState)
        return

    State := ServerManagerState
    try State.Gui.Destroy()
    ServerManagerState := 0

    State.Parent.Opt("-Disabled")
    State.Parent.Show()
    try WinActivate("ahk_id " State.Parent.Hwnd)
}


RefreshServerManager(PreferredServerKey := "") {
    global ServerManagerState
    global ServerList, Servers

    if !IsObject(ServerManagerState)
        return

    State := ServerManagerState
    if PreferredServerKey = ""
        PreferredServerKey := GetSelectedServerManagerKey()

    Names := []
    Keys := []
    SelectedIndex := 0

    for ServerKey in ServerList {
        if !Servers.Has(ServerKey)
            continue

        Keys.Push(ServerKey)
        Names.Push(Servers[ServerKey].Name)

        if ServerKey = PreferredServerKey
            SelectedIndex := Keys.Length
    }

    State.ServerControl.Delete()
    if Names.Length
        State.ServerControl.Add(Names)

    State.ServerKeys := Keys
    if !SelectedIndex && Keys.Length
        SelectedIndex := 1

    State.ServerControl.Choose(SelectedIndex)
    UpdateServerManagerDetails()
}


GetSelectedServerManagerKey() {
    global ServerManagerState

    if !IsObject(ServerManagerState)
        return ""

    Index := ServerManagerState.ServerControl.Value
    if Index < 1 || Index > ServerManagerState.ServerKeys.Length
        return ""

    return ServerManagerState.ServerKeys[Index]
}


UpdateServerManagerDetails(*) {
    global ServerManagerState
    global Servers

    if !IsObject(ServerManagerState)
        return

    State := ServerManagerState
    ServerKey := GetSelectedServerManagerKey()

    if ServerKey = "" || !Servers.Has(ServerKey) {
        State.SummaryText.Text := "No llama servers are registered."
        State.EditButton.Enabled := false
        State.DeleteButton.Enabled := false
        return
    }

    Server := Servers[ServerKey]
    State.SummaryText.Text := Server.Address ":" Server.Port "`n" Server.Executable
    State.EditButton.Enabled := true
    State.DeleteButton.Enabled := true
}


EditSelectedServer(*) {
    global ServerManagerState

    ServerKey := GetSelectedServerManagerKey()
    if ServerKey != ""
        OpenServerEditor(ServerManagerState.Gui, ServerKey)
}


DeleteSelectedServer(*) {
    global Servers

    ServerKey := GetSelectedServerManagerKey()
    if ServerKey = "" || !Servers.Has(ServerKey)
        return

    Server := Servers[ServerKey]
    ModelNames := GetModelsUsingServer(ServerKey)
    Message := "Delete llama server '" Server.Name "'?"

    if ModelNames.Length {
        Message .= "`n`nThis server is referenced by:"
        for ModelName in ModelNames
            Message .= "`n  • " ModelName

        Message .= "`n`nThose models will not be startable until another server is assigned."
    }

    if MsgBox(Message, "Delete Llama Server", "YesNo Icon?") != "Yes"
        return

    DeleteServer(ServerKey)
    RefreshServerManager()
    NotifyServerManagerChanged(GetSelectedServerManagerKey())
}


OpenServerEditor(ParentGui, ServerKey := "") {
    global ServerEditorState
    global Servers
    global BaseColor, SecondaryColor, TextColor, MutedColor

    if IsObject(ServerEditorState) {
        try {
            ServerEditorState.Gui.Show()
            WinActivate("ahk_id " ServerEditorState.Gui.Hwnd)
            return
        }
        catch
            ServerEditorState := 0
    }

    Editing := ServerKey != "" && Servers.Has(ServerKey)
    Server := Editing
        ? Servers[ServerKey]
        : {Name: "", Executable: "", Address: "127.0.0.1", Port: 18080, Args: ""}

    EditorGui := Gui(, Editing ? "Edit Llama Server" : "Add Llama Server")
    EditorGui.Opt("+Owner" ParentGui.Hwnd " -MinimizeBox -MaximizeBox")
    ParentGui.Opt("+Disabled")
    EditorGui.BackColor := BaseColor
    EditorGui.MarginX := 24
    EditorGui.MarginY := 20
    ApplyDarkWindow(EditorGui)

    EditorGui.SetFont("s14 Bold c" TextColor, "Segoe UI")
    EditorGui.AddText("xm w480 Center", Editing ? "EDIT LLAMA SERVER" : "ADD LLAMA SERVER")

    EditorGui.SetFont("s12 Norm c" TextColor, "Segoe UI")
    EditorGui.AddText("x24 y70", "Name")
    NameEdit := EditorGui.AddEdit("x24 y99 w480 Background" SecondaryColor " c" TextColor, Server.Name)

    EditorGui.AddText("x24 y145", "Executable")
    ExecutableEdit := EditorGui.AddEdit(
        "x24 y174 w438 Background" SecondaryColor " c" TextColor, Server.Executable
    )

    EditorGui.SetFont("s11 c" TextColor, "Segoe UI")
    BrowseButton := EditorGui.AddButton("x470 y173 w34 h26", "…")
    MakeOwnerDrawButton(BrowseButton)

    EditorGui.SetFont("s12 Norm c" TextColor, "Segoe UI")
    EditorGui.AddText("x24 y220", "Address")
    EditorGui.AddText("x374 y220", "Port")
    AddressEdit := EditorGui.AddEdit(
        "x24 y249 w330 Background" SecondaryColor " c" TextColor, Server.Address
    )
    PortEdit := EditorGui.AddEdit(
        "x374 y249 w130 Number Background" SecondaryColor " c" TextColor, Server.Port
    )

    EditorGui.AddText("x24 y295", "Optional arguments")
    ArgsEdit := EditorGui.AddEdit("x24 y324 w480 Background" SecondaryColor " c" TextColor, Server.Args)

    EditorGui.SetFont("s10 c" MutedColor, "Segoe UI")
    EditorGui.AddText(
        "x24 y365 w480",
        Editing ? "INI section: [" ServerKey "]" : "INI section will be generated from the server name."
    )

    EditorGui.SetFont("s12 c" TextColor, "Segoe UI")
    SaveButton := EditorGui.AddButton("x24 y397 w230 h42", "Save")
    CancelButton := EditorGui.AddButton("x274 yp w230 h42", "Cancel")
    MakeOwnerDrawButton(SaveButton)
    MakeOwnerDrawButton(CancelButton)

    ServerEditorState := {
        Gui: EditorGui, Parent: ParentGui, ServerKey: ServerKey, NameEdit: NameEdit,
        ExecutableEdit: ExecutableEdit, AddressEdit: AddressEdit, PortEdit: PortEdit, ArgsEdit: ArgsEdit
    }

    BrowseButton.OnEvent("Click", (*) => BrowseServerExecutable(ExecutableEdit))
    SaveButton.OnEvent("Click", SaveServerEditor)
    CancelButton.OnEvent("Click", CloseServerEditor)
    EditorGui.OnEvent("Close", CloseServerEditor)
    ShowRelative(EditorGui, ParentGui)
}


BrowseServerExecutable(ExecutableEdit) {
    SelectedPath := FileSelect(
        1, Trim(ExecutableEdit.Text), "Select llama-server executable", "Programs (*.exe)"
    )

    if SelectedPath != ""
        ExecutableEdit.Text := SelectedPath
}


SaveServerEditor(*) {
    global ServerEditorState

    if !IsObject(ServerEditorState)
        return

    State := ServerEditorState
    Name := Trim(State.NameEdit.Text)
    Executable := Trim(State.ExecutableEdit.Text)
    Address := Trim(State.AddressEdit.Text)
    Port := Trim(State.PortEdit.Text)
    Args := Trim(State.ArgsEdit.Text)

    if Name = "" {
        MsgBox("Enter a name for the llama server.", "Llama Server", "Icon!")
        return
    }

    if Executable = "" {
        MsgBox("Enter the llama-server executable location.", "Llama Server", "Icon!")
        return
    }

    if !FileExist(Executable) {
        MsgBox(
            "Llama server executable not found:`n`n" Executable,
            "Llama Server",
            "Icon!"
        )
        return
    }

    if Address = "" {
        MsgBox("Enter the address used by the llama server.", "Llama Server", "Icon!")
        return
    }

    if !IsInteger(Port) || Port < 1 || Port > 65535 {
        MsgBox("Port must be an integer from 1 through 65535.", "Llama Server", "Icon!")
        return
    }

    SavedKey := State.ServerKey != ""
        ? SaveServer(State.ServerKey, Name, Executable, Address, Port, Args)
        : AddServer(Name, Executable, Address, Port, Args)

    CloseServerEditor()
    RefreshServerManager(SavedKey)
    NotifyServerManagerChanged(SavedKey)
}


CloseServerEditor(*) {
    global ServerEditorState

    if !IsObject(ServerEditorState)
        return

    State := ServerEditorState
    try State.Gui.Destroy()
    ServerEditorState := 0

    State.Parent.Opt("-Disabled")
    State.Parent.Show()
    try WinActivate("ahk_id " State.Parent.Hwnd)
}


NotifyServerManagerChanged(ServerKey := "") {
    global ServerManagerState

    if !IsObject(ServerManagerState)
        return

    Callback := ServerManagerState.OnChanged
    if IsObject(Callback)
        Callback.Call(ServerKey)
}

; ============================================================
;  SERVERS
; ============================================================

LoadServers() {
    global ServerList

    Servers := Map()

    for Key in ServerList {
        Servers[Key] := {
            Name: ConfigRead(
                Key,
                "Name",
                Key
            ),

            Executable: ConfigRead(
                Key,
                "Executable",
                ""
            ),

            Address: ConfigRead(
                Key,
                "Address",
                "127.0.0.1"
            ),

            Port: ConfigReadInteger(
                Key,
                "Port",
                18080,
                1,
                65535
            ),

            Args: ConfigRead(
                Key,
                "Args",
                ""
            )
        }
    }

    return Servers
}

SaveServer(
    ServerKey,
    Name,
    Executable,
    Address,
    Port,
    Args := ""
) {
    global Servers
    global ServerList

    Server := {
        Name: Name,
        Executable: Executable,
        Address: Address,
        Port: Port + 0,
        Args: Args
    }

    ConfigWriteMany(
        ServerKey,
        Map(
            "Name", Server.Name,
            "Executable", Server.Executable,
            "Address", Server.Address,
            "Port", Server.Port,
            "Args", Server.Args
        )
    )

    if !ListContainsValue(
        ServerList,
        ServerKey
    ) {
        ServerList.Push(
            ServerKey
        )

        ConfigWriteList(
            "General",
            "ServerList",
            ServerList
        )
    }

    Servers[
        ServerKey
    ] := Server

    return ServerKey
}


AddServer(
    Name,
    Executable,
    Address := "127.0.0.1",
    Port := 18080,
    Args := ""
) {
    ServerKey :=
        GenerateConfigKey(
            Name,
            "Server"
        )

    return SaveServer(
        ServerKey,
        Name,
        Executable,
        Address,
        Port,
        Args
    )
}


DeleteServer(ServerKey) {
    global Servers
    global ServerList

    if !ListContainsValue(
        ServerList,
        ServerKey
    )
        return false

    ConfigDeleteSection(
        ServerKey
    )

    RemoveListValue(
        ServerList,
        ServerKey
    )

    ConfigWriteList(
        "General",
        "ServerList",
        ServerList
    )

    if Servers.Has(
        ServerKey
    )
        Servers.Delete(
            ServerKey
        )

    return true
}


GetModelsUsingServer(ServerKey) {
    global Models, ModelList

    ModelNames := []
    SearchKey := StrLower(Trim(ServerKey))

    for ModelKey in ModelList {
        if Models.Has(ModelKey)
        && StrLower(Trim(Models[ModelKey].ServerKey)) = SearchKey
            ModelNames.Push(Models[ModelKey].Name)
    }

    return ModelNames
}


ServerExists(ServerKey) {
    global Servers

    return Servers.Has(
        ServerKey
    )
}


GetServer(ServerKey) {
    global Servers

    if !Servers.Has(
        ServerKey
    )
        return false

    return Servers[
        ServerKey
    ]
}

GetModelServer(ModelKey) {
    global Models
    global Servers

    if !Models.Has(ModelKey)
        return false

    ServerKey :=
        Models[ModelKey].ServerKey

    if ServerKey = ""
    || !Servers.Has(ServerKey)
        return false

    return Servers[ServerKey]
}


GetServerWebUI(Server) {
    Address := Trim(
        Server.Address
    )

    if RegExMatch(
        Address,
        "i)^https?://"
    ) {
        return RTrim(
            Address,
            "/"
        )
            . ":"
            . Server.Port
    }

    return "http://"
        . Address
        . ":"
        . Server.Port
}


GetModelWebUI(ModelKey, ServerKey := "") {
    Server := ServerKey != ""
        ? GetServer(ServerKey)
        : GetModelServer(ModelKey)

    if !Server
        return ""

    return GetServerWebUI(Server)
}


GetModelHealthURL(ModelKey, ServerKey := "") {
    WebUI :=
        GetModelWebUI(
            ModelKey,
            ServerKey
        )

    if WebUI = ""
        return ""

    return WebUI "/health"
}

; ============================================================
;  APPLICATION FUNCTIONS
; ============================================================

CleanupOwnedServices(ExitReason, ExitCode) {
    global LlamaPid, McpPid

    if LlamaPid && ProcessExist(LlamaPid)
        StopProcessTree(LlamaPid)

    if McpPid && ProcessExist(McpPid)
        StopProcessTree(McpPid)
}

SetActivePollRate(Rate) {
    global ActivePollRate

    if ActivePollRate = Rate
        return

    ActivePollRate := Rate

    SetTimer(
        UpdateActiveState,
        Rate
    )
}

HideController(GuiObj, *) {
    GuiObj.Hide()
}


ShowController(*) {
    global ControllerMode
    global MainGui, ActiveGui

    if ControllerMode = "active"
        Window := ActiveGui
    else
        Window := MainGui

    Window.Show()

    WinActivate(
        "ahk_id " Window.Hwnd
    )
}

OpenChat(*) {
    global ActiveModelKey, ActiveServerKey

    WebUI :=
        GetModelWebUI(
            ActiveModelKey,
            ActiveServerKey
        )

    if WebUI = "" {
        MsgBox(
            "The active model does not reference a registered llama server.",
            "Local AI",
            "Icon!"
        )

        return
    }

    Run(
        WebUI
    )
}

GetListeningPid(Port) {
    Shell := ComObject(
        "WScript.Shell"
    )

    Command :=
        A_ComSpec
        . " /c netstat -ano -p TCP"
        . " | findstr LISTENING"
        . " | findstr :" Port

    Exec := Shell.Exec(
        Command
    )

    Output := Exec.StdOut.ReadAll()

    for Line in StrSplit(Output, "`n") {
        Line := Trim(Line)

        if Line = ""
            continue

        Fields := StrSplit(
            RegExReplace(
                Line,
                "\s+",
                " "
            ),
            " "
        )

        if Fields.Length < 5
            continue

        LocalAddress := Fields[2]

        ; Make sure :18080 doesn't accidentally match :180800, etc.
        if !RegExMatch(
            LocalAddress,
            ":" Port "$"
        )
            continue

        Pid := Fields[5]

        if IsInteger(Pid)
            return Pid + 0
    }

    return 0
}

ShowRelative(NewGui, OldGui) {
    ; --------------------------------------------------------
    ;  OLD WINDOW: physical desktop coordinates
    ; --------------------------------------------------------

    OldRect := Buffer(16)

    DllCall(
        "user32\GetWindowRect",
        "ptr", OldGui.Hwnd,
        "ptr", OldRect
    )

    OldX := NumGet(OldRect, 0, "Int")
    OldY := NumGet(OldRect, 4, "Int")

    OldRight := NumGet(OldRect, 8, "Int")
    OldBottom := NumGet(OldRect, 12, "Int")

    OldW := OldRight - OldX
    OldH := OldBottom - OldY


    ; --------------------------------------------------------
    ;  NEW WINDOW: create invisibly at natural size
    ; --------------------------------------------------------

    NewGui.Show("Hide AutoSize")

    NewRect := Buffer(16)

    DllCall(
        "user32\GetWindowRect",
        "ptr", NewGui.Hwnd,
        "ptr", NewRect
    )

    NewW :=
        NumGet(NewRect, 8, "Int")
        - NumGet(NewRect, 0, "Int")

    NewH :=
        NumGet(NewRect, 12, "Int")
        - NumGet(NewRect, 4, "Int")


    ; --------------------------------------------------------
    ;  CENTER ACTUAL WINDOW RECTANGLES
    ; --------------------------------------------------------

    NewX := Round(
        OldX + (OldW - NewW) / 2
    )

    NewY := Round(
        OldY + (OldH - NewH) / 2
    )


    ; --------------------------------------------------------
    ;  VIRTUAL-DESKTOP CLAMP
    ; --------------------------------------------------------

    ClampToDesktop(
        &NewX,
        &NewY,
        NewW,
        NewH
    )


    ; --------------------------------------------------------
    ;  MOVE IN PHYSICAL SCREEN COORDINATES
    ; --------------------------------------------------------

    DllCall(
        "user32\SetWindowPos",
        "ptr", NewGui.Hwnd,
        "ptr", 0,
        "int", NewX,
        "int", NewY,
        "int", 0,
        "int", 0,
        "uint", 0x0001 | 0x0004
    )

    NewGui.Show()
}


ClampToDesktop(&X, &Y, Width, Height) {
    ; Windows virtual desktop: all monitors treated as one
    ; continuous coordinate space.
    DesktopX := SysGet(76)  ; SM_XVIRTUALSCREEN
    DesktopY := SysGet(77)  ; SM_YVIRTUALSCREEN
    DesktopW := SysGet(78)  ; SM_CXVIRTUALSCREEN
    DesktopH := SysGet(79)  ; SM_CYVIRTUALSCREEN

    DesktopRight := DesktopX + DesktopW
    DesktopBottom := DesktopY + DesktopH

    ; Only interfere if the window would actually leave
    ; the total desktop bounds.
    if X < DesktopX
        X := DesktopX

    if Y < DesktopY
        Y := DesktopY

    if X + Width > DesktopRight
        X := DesktopRight - Width

    if Y + Height > DesktopBottom
        Y := DesktopBottom - Height
}

; ============================================================
;  DARK THEME
; ============================================================

ApplyDarkWindow(Window) {
    ; Dark client area is handled explicitly with Window.BackColor.
    ; This asks Windows to darken the native title bar as well.

    Dark := 1

    try {
        Result := DllCall(
            "dwmapi\DwmSetWindowAttribute",
            "ptr",
            Window.Hwnd,
            "int",
            20,
            "int*",
            Dark,
            "int",
            4
        )

        ; Older Windows 10 builds used attribute 19.
        if Result != 0 {
            DllCall(
                "dwmapi\DwmSetWindowAttribute",
                "ptr",
                Window.Hwnd,
                "int",
                19,
                "int*",
                Dark,
                "int",
                4
            )
        }
    }
}

; ============================================================
;  OWNER-DRAWN DARK CONTROLS
; ============================================================

DarkMeasureItem(wParam, lParam, msg, hwnd) {
    CtlType := NumGet(lParam, 0, "UInt")

    ; ODT_COMBOBOX = 3
    if CtlType != 3
        return

    ; MEASUREITEMSTRUCT.itemHeight
    NumPut(
        "UInt",
        Round(30 * A_ScreenDPI / 96),
        lParam,
        16
    )

    return true
}


DarkDrawItem(wParam, lParam, msg, hwnd) {
    CtlType := NumGet(lParam, 0, "UInt")

    switch CtlType {
        case 3:  ; ODT_COMBOBOX
            return DrawDarkComboItem(lParam)

        case 4:  ; ODT_BUTTON
            return DrawDarkButton(lParam)
    }
}

MakeOwnerDrawButton(Control) {
    static BM_SETSTYLE := 0x00F4
    static BS_OWNERDRAW := 0x000B

    DllCall(
        "user32\SendMessageW",
        "ptr", Control.Hwnd,
        "uint", BM_SETSTYLE,
        "ptr", BS_OWNERDRAW,
        "ptr", 1
    )

    DllCall(
        "user32\InvalidateRect",
        "ptr", Control.Hwnd,
        "ptr", 0,
        "int", true
    )
}

DrawDarkComboItem(lParam) {
    global SecondaryBrush, SelectedBrush
    global TextColor, MutedColor

    ItemID := NumGet(lParam, 8, "UInt")
    State  := NumGet(lParam, 16, "UInt")

    HwndOffset := A_PtrSize = 8 ? 24 : 20
    DcOffset   := A_PtrSize = 8 ? 32 : 24
    RectOffset := A_PtrSize = 8 ? 40 : 28

    ControlHwnd := NumGet(lParam, HwndOffset, "Ptr")
    Hdc         := NumGet(lParam, DcOffset, "Ptr")
    RectPtr     := lParam + RectOffset

    ODS_SELECTED := 0x0001
    ODS_DISABLED := 0x0004

    Brush :=
        State & ODS_SELECTED
        ? SelectedBrush
        : SecondaryBrush

    DllCall(
        "user32\FillRect",
        "ptr", Hdc,
        "ptr", RectPtr,
        "ptr", Brush
    )

    ; 0xFFFFFFFF means no valid item.
    if ItemID = 0xFFFFFFFF
        return true

    Text := GetComboItemText(
        ControlHwnd,
        ItemID
    )

    Color :=
        State & ODS_DISABLED
        ? HexToColorRef(MutedColor)
        : HexToColorRef(TextColor)

    DllCall(
        "gdi32\SetTextColor",
        "ptr", Hdc,
        "uint", Color
    )

    DllCall(
        "gdi32\SetBkMode",
        "ptr", Hdc,
        "int", 1          ; TRANSPARENT
    )

    TextRect := Buffer(16, 0)

    Left   := NumGet(RectPtr, 0, "Int")
    Top    := NumGet(RectPtr, 4, "Int")
    Right  := NumGet(RectPtr, 8, "Int")
    Bottom := NumGet(RectPtr, 12, "Int")

    Padding := Round(9 * A_ScreenDPI / 96)

    NumPut(
        "Int", Left + Padding,
        "Int", Top,
        "Int", Right - Padding,
        "Int", Bottom,
        TextRect
    )

    DllCall(
        "user32\DrawTextW",
        "ptr", Hdc,
        "str", Text,
        "int", -1,
        "ptr", TextRect,
        "uint", 0x0824
    )

    return true
}


DrawDarkButton(lParam) {
    global SecondaryBrush, SelectedBrush, BorderBrush
    global TextColor, MutedColor
	global DarkButtonFillOverrides

    State := NumGet(lParam, 16, "UInt")

    HwndOffset := A_PtrSize = 8 ? 24 : 20
    DcOffset   := A_PtrSize = 8 ? 32 : 24
    RectOffset := A_PtrSize = 8 ? 40 : 28

    ControlHwnd := NumGet(lParam, HwndOffset, "Ptr")
    Hdc         := NumGet(lParam, DcOffset, "Ptr")
    RectPtr     := lParam + RectOffset

    ODS_SELECTED := 0x0001
    ODS_DISABLED := 0x0004
    ODS_FOCUS    := 0x0010
    ODS_HOTLIGHT := 0x0040

	if State & ODS_SELECTED
		Brush := SecondaryBrush

	else if DarkButtonFillOverrides.Has(ControlHwnd)
		Brush := DarkButtonFillOverrides[ControlHwnd]

	else
		Brush := SelectedBrush

    DllCall(
        "user32\FillRect",
        "ptr", Hdc,
        "ptr", RectPtr,
        "ptr", Brush
    )

    DllCall(
        "user32\FrameRect",
        "ptr", Hdc,
        "ptr", RectPtr,
        "ptr", BorderBrush
    )

    Text := GetHwndText(ControlHwnd)

    Color :=
        State & ODS_DISABLED
        ? HexToColorRef(MutedColor)
        : HexToColorRef(TextColor)

    DllCall(
        "gdi32\SetTextColor",
        "ptr", Hdc,
        "uint", Color
    )

    DllCall(
        "gdi32\SetBkMode",
        "ptr", Hdc,
        "int", 1
    )

    DllCall(
        "user32\DrawTextW",
        "ptr", Hdc,
        "str", Text,
        "int", -1,
        "ptr", RectPtr,
        "uint", 0x0825
    )

    return true
}


; ============================================================
;  COMBO TEXT
; ============================================================

GetComboItemText(ControlHwnd, ItemID) {
    CB_GETLBTEXTLEN := 0x0149
    CB_GETLBTEXT    := 0x0148

    Length := DllCall(
        "user32\SendMessageW",
        "ptr", ControlHwnd,
        "uint", CB_GETLBTEXTLEN,
        "ptr", ItemID,
        "ptr", 0,
        "ptr"
    )

    if Length < 0
        return ""

    TextBuffer := Buffer(
        (Length + 1) * 2,
        0
    )

    DllCall(
        "user32\SendMessageW",
        "ptr", ControlHwnd,
        "uint", CB_GETLBTEXT,
        "ptr", ItemID,
        "ptr", TextBuffer.Ptr,
        "ptr"
    )

    return StrGet(TextBuffer, Length, "UTF-16")
}


GetHwndText(ControlHwnd) {
    Length := DllCall(
        "user32\GetWindowTextLengthW",
        "ptr", ControlHwnd
    )

    TextBuffer := Buffer(
        (Length + 1) * 2,
        0
    )

    DllCall(
        "user32\GetWindowTextW",
        "ptr", ControlHwnd,
        "ptr", TextBuffer.Ptr,
        "int", Length + 1
    )

    return StrGet(TextBuffer, Length, "UTF-16")
}


; ============================================================
;  COLOR HELPERS
; ============================================================

CreateBrush(HexColor) {
    return DllCall(
        "gdi32\CreateSolidBrush",
        "uint", HexToColorRef(HexColor),
        "ptr"
    )
}


HexToColorRef(HexColor) {
    Value := Integer("0x" HexColor)

    R := (Value >> 16) & 0xFF
    G := (Value >> 8) & 0xFF
    B := Value & 0xFF

    return R | (G << 8) | (B << 16)
}


DarkListBox(wParam, lParam, msg, hwnd) {
    global SecondaryBrush
    global SecondaryColor, TextColor

    DllCall(
        "gdi32\SetBkColor",
        "ptr", wParam,
        "uint", HexToColorRef(SecondaryColor)
    )

    DllCall(
        "gdi32\SetTextColor",
        "ptr", wParam,
        "uint", HexToColorRef(TextColor)
    )

    return SecondaryBrush
}

ApplyDarkControl(Control) {
    try {
        ; More complete dark rendering for common dialog-style controls.
        DllCall(
            "uxtheme\SetWindowTheme",
            "ptr",
            Control.Hwnd,
            "str",
            "DarkMode_CFD",
            "ptr",
            0
        )

        ; ComboBoxes have child windows which may keep the light theme.
        if Control.Type = "ComboBox" || Control.Type = "DDL" {
            Child := DllCall(
                "user32\GetWindow",
                "ptr",
                Control.Hwnd,
                "uint",
                5,          ; GW_CHILD
                "ptr"
            )

            while Child {
                DllCall(
                    "uxtheme\SetWindowTheme",
                    "ptr",
                    Child,
                    "str",
                    "DarkMode_CFD",
                    "ptr",
                    0
                )

                Child := DllCall(
                    "user32\GetWindow",
                    "ptr",
                    Child,
                    "uint",
                    2,      ; GW_HWNDNEXT
                    "ptr"
                )
            }
        }
    }
}

