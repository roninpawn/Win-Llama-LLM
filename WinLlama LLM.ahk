#Requires AutoHotkey v2.0
#SingleInstance Off

Persistent true

;@Ahk2Exe-SetDescription WinLlama LLM
;@Ahk2Exe-SetCompanyName Roninpawn
;@Ahk2Exe-SetVersion 0.1.0
;@Ahk2Exe-SetMainIcon WinLlama LLM.ico

InstanceMutex := AcquireInstanceMutex()

if !InstanceMutex
    ExitApp

OnExit(CleanupOwnedServices)

; ============================================================
;  APPLICATION
; ============================================================

AppName := "WinLlama LLM"
AppVersion := "0.1.0"
AppWindowTitle := AppName " v" AppVersion

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
EnsureConfigFile()

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
    ""
)

SavedWindowCenterX := Trim(
    ConfigRead(
        "State",
        "WindowCenterX",
        ""
    )
)

SavedWindowCenterY := Trim(
    ConfigRead(
        "State",
        "WindowCenterY",
        ""
    )
)

if !IsInteger(SavedWindowCenterX)
    SavedWindowCenterX := ""

if !IsInteger(SavedWindowCenterY)
    SavedWindowCenterY := ""

McpEnabled := ConfigReadBoolean(
    "MCP",
    "Enabled",
    false
)

McpProxyExecutable := ConfigRead(
    "MCP",
    "ProxyExecutable",
    ""
)

McpProxyAutoDiscovered := false

if Trim(McpProxyExecutable) = "" {
    DiscoveredMcpProxy := DiscoverMcpProxyExecutable()

    if DiscoveredMcpProxy != "" {
        McpProxyExecutable := DiscoveredMcpProxy
        McpProxyAutoDiscovered := true
    }
}

McpAddress := ConfigRead(
    "MCP",
    "Address",
    "127.0.0.1"
)

McpPort := ConfigReadInteger(
    "MCP",
    "Port",
    9932,
    1,
    65535
)

McpDirectories := ConfigRead(
    "MCP",
    "GlobalDirectories",
    ""
)

ContextPresets := [
    "4096",
    "8192",
    "12288",
    "16384",
    "24576",
    "32768",
    "49152",
    "65536",
    "98304",
    "131072",
    "196608",
    "262144"
]

KvCacheOptions := [
    "f32",
    "f16",
    "bf16",
    "q8_0",
    "q4_0",
    "q4_1",
    "iq4_nl",
    "q5_0",
    "q5_1"
]

LogsDirectory := ResolvePath(
    ConfigRead(
        "General",
        "LogsDirectory",
        "Logs"
    )
)

EnsureLoggingDefaults()

DefaultLogFlushInterval := 5000

LogFlushInterval := ConfigReadInteger(
    "Logging",
    "FlushInterval",
    DefaultLogFlushInterval
)

if LogFlushInterval <= 0
    LogFlushInterval := DefaultLogFlushInterval

LlamaLogSessions := ConfigReadInteger(
    "Logging",
    "LlamaSessions",
    10
)

if LlamaLogSessions <= 0
    LlamaLogSessions := 10

McpLogSessions := ConfigReadInteger(
    "Logging",
    "McpSessions",
    3
)

if McpLogSessions <= 0
    McpLogSessions := 3

CapturePollInterval := 50

Servers := LoadServers()
Models := LoadModels()
NeedsSetup := ConfigurationNeedsSetup()

LlamaPid := 0
McpPid := 0

LlamaLog := ""
McpLog := ""

if !DirExist(LogsDirectory)
    DirCreate(LogsDirectory)

LogStreams := Map(
    "llama", {FilePath: "", Buffer: "", Dirty: false},
    "mcp",   {FilePath: "", Buffer: "", Dirty: false}
)

CapturedProcesses := Map()

McpPollState := {
    Active: false,
    Additional: 0,
    LatestRaw: "",
    LatestDisplay: "",
    ViewerTallyStart: 0
}

ControllerMode := "start"

ActiveHasLaunched := false

ActiveModelKey := ""
ActiveServerKey := ""
ActiveServerConfig := 0
ActiveContext := 0
ActiveCache := ""
ActiveModelMcpDirectories := ""
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

; Once llama is known Offline, stop automatic HTTP probes until
; the user explicitly starts/restarts it or a new session begins.
LlamaProbeSuppressed := false
McpProbeSuppressed := false

LlamaStartupUntil := 0
McpStartupUntil := 0
LlamaStartupGrace := 60000
McpStartupGrace := 20000

; ============================================================
; LOG VIEWER GLOBALS
; ============================================================

ConsoleGui := 0
ConsoleOutput := 0
ConsoleOutputNoWrap := 0
ConsoleOutputWrap := 0

ConsoleActiveTab := "llama"

ConsoleLlamaText := ""
ConsoleMcpText := ""
ConsoleLlamaRevision := 0
ConsoleMcpRevision := 0
ConsoleRenderedText := ""
ConsoleRenderedRevision := -1

ConsoleEffectiveRate := 250
ConsoleRateCheckInterval := 250

ConsoleWrapEnabled := false

ConsoleMinRate := 100
ConsoleMaxRate := 86400000

DarkButtonFillOverrides := Map()

SetupHostGui := 0
SetupSelectedModelKey := ""

SetTimer(
    PollCapturedProcesses,
    CapturePollInterval
)

try SetTimer(
    FlushDirtyLogs,
    LogFlushInterval
)
catch {
    LogFlushInterval := DefaultLogFlushInterval

    SetTimer(
        FlushDirtyLogs,
        LogFlushInterval
    )
}

; ============================================================
;  CONFIGURATION BOOTSTRAP
; ============================================================

EnsureConfigFile() {
    global ConfigFile

    if FileExist(ConfigFile)
        return false

    ConfigWriteMany(
        "General",
        Map(
            "ModelList", "",
            "ServerList", "",
            "LogsDirectory", "Logs"
        )
    )

    ConfigWriteMany(
        "MCP",
        Map(
            "Enabled", "false",
            "ProxyExecutable", "",
            "Address", "127.0.0.1",
            "Port", 9932,
            "GlobalDirectories", ""
        )
    )

    ConfigWriteMany(
        "Logging",
        Map(
            "FlushInterval", 5000,
            "LlamaSessions", 10,
            "McpSessions", 3
        )
    )

    return true
}


EnsureLoggingDefaults() {
    Missing := "__WINLLAMA_MISSING__"

    if ConfigRead(
        "Logging",
        "FlushInterval",
        Missing
    ) = Missing
        ConfigWrite(
            "Logging",
            "FlushInterval",
            5000
        )

    if ConfigRead(
        "Logging",
        "LlamaSessions",
        Missing
    ) = Missing
        ConfigWrite(
            "Logging",
            "LlamaSessions",
            10
        )

    if ConfigRead(
        "Logging",
        "McpSessions",
        Missing
    ) = Missing
        ConfigWrite(
            "Logging",
            "McpSessions",
            3
        )
}


ConfigurationNeedsSetup() {
    global ServerList
    global ModelList

    HasServer := false

    for ServerKey in ServerList {
        if IsStructurallyValidServer(ServerKey) {
            HasServer := true
            break
        }
    }

    if !HasServer
        return true

    for ModelKey in ModelList {
        if IsStructurallyValidModel(ModelKey)
            return false
    }

    return true
}


IsStructurallyValidServer(ServerKey) {
    global Servers

    return ServerKey != ""
        && Servers.Has(ServerKey)
        && Trim(Servers[ServerKey].Executable) != ""
}


IsStructurallyValidModel(ModelKey) {
    global Models, Servers

    if ModelKey = "" || !Models.Has(ModelKey)
        return false

    Model := Models[ModelKey]

    return Trim(Model.Model) != ""
        && Trim(Model.ServerKey) != ""
        && IsStructurallyValidServer(Model.ServerKey)
}


StartSetupSequence() {
    global ControllerMode
    global SetupHostGui

    ControllerMode := "setup"

    if !IsObject(SetupHostGui) {
        SetupHostGui := Gui("+ToolWindow", "WinLlama Setup")
        SetupHostGui.Show("Hide w552 h420 Center")
    }

    OpenServerManager(
        SetupHostGui,
        "",
        0,
        true,
        ContinueSetupFromServer
    )
}


ContinueSetupFromServer(ServerKey) {
    global SetupHostGui

    OpenModelConfigEditor(
        SetupHostGui,
        GetSetupPreferredModelKey(),
        "",
        "",
        ServerKey,
        "setup"
    )
}


GetSetupPreferredModelKey() {
    global LastModel
    global ModelList, Models

    if LastModel != "" && Models.Has(LastModel)
        return LastModel

    for ModelKey in ModelList {
        if Models.Has(ModelKey)
            return ModelKey
    }

    return ""
}


ContinueSetupFromModel(EditorGui, ParentGui, ModelPanel) {
    global Models, Servers
    global SetupSelectedModelKey

    Values := ModelPanel.GetValues()

    if !Values
        return

    if !IsStructurallyValidServer(Values.ServerKey) {
        MsgBox(
            "Select a registered llama server for this model.",
            "WinLlama Setup",
            "Icon!"
        )
        return
    }

    if !Models.Has(Values.ModelKey)
    || Trim(Models[Values.ModelKey].Model) = "" {
        MsgBox(
            "Select or add a model with a configured GGUF location.",
            "WinLlama Setup",
            "Icon!"
        )
        return
    }

    SaveModelDefaults(
        Values.ModelKey,
        Values.ServerKey,
        Values.Context,
        Values.Cache,
        Values.McpDirectories
    )

    SaveLastModel(Values.ModelKey)
    SetupSelectedModelKey := Values.ModelKey

    EndConfigDialog(
        EditorGui,
        ParentGui,
        false
    )

    OpenSetupMcpStep()
}


OpenSetupMcpStep() {
    global SetupHostGui

    OpenMcpConfigEditor(
        SetupHostGui,
        false,
        true
    )
}


SaveSetupMcpAndContinue(EditorGui, ParentGui, McpPanel) {
    if !SaveMcpEditorConfig(McpPanel)
        return

    EndConfigDialog(
        EditorGui,
        ParentGui,
        false
    )

    FinishSetupSequence()
}


SkipSetupMcp(EditorGui, ParentGui) {
    EndConfigDialog(
        EditorGui,
        ParentGui,
        false
    )

    FinishSetupSequence()
}


FinishSetupSequence() {
    global ControllerMode
    global NeedsSetup
    global SetupHostGui
    global SetupSelectedModelKey
    global MainGui
    global LastModel
    global ModelList, Models

    if ConfigurationNeedsSetup() {
        MsgBox(
            "WinLlama still needs a registered llama server and model before setup can finish.",
            "WinLlama Setup",
            "Icon!"
        )

        StartSetupSequence()
        return
    }

    if IsObject(SetupHostGui) {
        try SetupHostGui.Destroy()
        SetupHostGui := 0
    }

    ControllerMode := "start"
    NeedsSetup := false

    PreferredModelKey := SetupSelectedModelKey

    if PreferredModelKey = "" || !Models.Has(PreferredModelKey) {
        PreferredModelKey := LastModel != "" && Models.Has(LastModel)
            ? LastModel
            : ModelList[1]
    }

    RefreshMainModelControl(PreferredModelKey)
    UpdateMainModelInfo()
    ShowStartupWindow()
    WinActivate("ahk_id " MainGui.Hwnd)
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

SaveMcpDefaults(Enabled, ProxyExecutable, Address, Port, Directories) {
    global McpEnabled, McpProxyExecutable, McpAddress, McpPort
    global McpDirectories

    ProxyExecutable := Trim(ProxyExecutable)
    Address := Trim(Address)

    ConfigWriteMany(
        "MCP",
        Map(
            "Enabled", Enabled ? "true" : "false",
            "ProxyExecutable", ProxyExecutable,
            "Address", Address,
            "Port", Port,
            "GlobalDirectories", Directories
        )
    )

    McpEnabled := Enabled
    McpProxyExecutable := ProxyExecutable
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

; ============================================================
;  TRAY MENU
; ============================================================

A_TrayMenu.Delete()

A_TrayMenu.Add("Open Controller", ShowController)

A_TrayMenu.Add()

A_TrayMenu.Add("Shutdown All", ShutdownAll)

A_TrayMenu.Default := "Open Controller"
A_TrayMenu.ClickCount := 2

A_IconTip := AppName

; ============================================================
;  STARTUP WINDOW
; ============================================================

MainGui := Gui(, AppWindowTitle)
MainGui.BackColor := BaseColor
MainGui.MarginX := 26
MainGui.MarginY := 22

ApplyDarkWindow(MainGui)

MainGui.SetFont("s16 Bold c" TextColor, "Segoe UI")
MainGui.AddText("xm w520 Center", "WinLlama LLM")

MainGui.SetFont("s12 Norm c" TextColor, "Segoe UI")
MainGui.AddText("xm y+24", "Model")

ModelNames := []
InitialIndex := 0
InitialModelKey := ""

if ModelList.Length {
    InitialModelKey :=
        LastModel != ""
        && Models.Has(LastModel)
            ? LastModel
            : ModelList[1]

    for Index, Key in ModelList {
        if !Models.Has(Key)
            continue

        ModelNames.Push(Models[Key].Name)

        if Key = InitialModelKey
            InitialIndex := ModelNames.Length
    }

    if !InitialIndex && ModelNames.Length
        InitialIndex := 1
}

MainModelControl := MainGui.AddDropDownList(
    "xm y+7 w520 +0x210",
    ModelNames
)

if InitialIndex
    MainModelControl.Choose(InitialIndex)

ApplyDarkControl(MainModelControl)

BuildActiveGui()


; ------------------------------------------------------------
;  MODEL INFORMATION
; ------------------------------------------------------------

MainGui.SetFont("s11 c" MutedColor, "Segoe UI")

MainServerText := MainGui.AddText(
    "xm y+16 w520",
    ""
)

MainContextText := MainGui.AddText(
    "xm y+4 w260",
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
MainGui.AddText("xm y+22 w478", "MCP Access")

MainGui.SetFont("s11 c" TextColor, "Segoe UI")
MainMcpEditButton := MainGui.AddButton(
    "x+16 yp-3 w26 h26",
    "…"
)
MakeOwnerDrawButton(MainMcpEditButton)

MainGui.SetFont("s11 c" MutedColor, "Segoe UI")
MainMcpText := MainGui.AddText(
    "xm y+7 w520 h74",
    ""
)


; ------------------------------------------------------------
;  BUTTONS
; ------------------------------------------------------------

MainGui.SetFont("s12 c" TextColor, "Segoe UI")

StartButton := MainGui.AddButton(
    "xm y+20 w250 h46",
    "Start"
)

ConfigButton := MainGui.AddButton(
    "x+20 yp w250 h46",
    "Configure Session"
)

MakeOwnerDrawButton(StartButton)
MakeOwnerDrawButton(ConfigButton)

StartButton.OnEvent("Click", StartSelected)
ConfigButton.OnEvent("Click", OpenSessionConfig)
MainMcpEditButton.OnEvent("Click", OpenMainMcpEditor)
MainModelControl.OnEvent("Change", UpdateMainModelInfo)

MainGui.OnEvent("Close", HideController)

UpdateMainModelInfo()

if NeedsSetup
    StartSetupSequence()
else
    ShowStartupWindow()


; ============================================================
;  STARTUP MODEL INFORMATION
; ============================================================

UpdateMainModelInfo(*) {
    global MainModelControl
    global MainContextText, MainCacheText, MainServerText
    global MainMcpText
    global ModelList, Models, Servers
    global McpEnabled, McpAddress, McpPort

    Index := MainModelControl.Value
    if Index < 1 || Index > ModelList.Length
        return

    Key := ModelList[Index]
    Model := Models[Key]

    MainContextText.Text := "Context:  " Model.Context
    MainCacheText.Text := "KV cache:  " Model.Cache

    if Servers.Has(Model.ServerKey) {
        Server := Servers[Model.ServerKey]
        MainServerText.Text :=
            "Server:  " Server.Name
            . "  •  " Server.Address ":" Server.Port
    }
    else {
        MainServerText.Text :=
            "Server:  Missing: " Model.ServerKey
    }

    if !McpEnabled {
        MainMcpText.Text := "Disabled"
        return
    }

    Directories := GetEffectiveMcpDirectories(Key)
    MainMcpText.Text := "mcp-proxy:  " McpAddress ":" McpPort

    if Trim(Directories) = "" {
        MainMcpText.Text .= "`nNo filesystem roots configured."
        return
    }

    MainMcpText.Text .= "`n" DisplayDirectories(Directories)
}


; ============================================================
;  START SELECTED MODEL WITH ITS DEFAULTS
; ============================================================

StartSelected(*) {
    global MainModelControl
    global ModelList, Models

    Key := ModelList[
        MainModelControl.Value
    ]

    Model := Models[Key]

    EnterActiveView(
        Key,
        Model.Context,
        Model.Cache,
        Model.ServerKey,
        Model.McpDirectories
    )

    LaunchAI(
        Key,
        "",
        ""
    )
}


OpenMainMcpEditor(*) {
    global MainGui

    OpenMcpConfigEditor(
        MainGui,
        false
    )
}

; ============================================================
;  REUSABLE CONFIG PANELS
; ============================================================

class ModelConfigPanel {
    __New(GuiObj, X, Y, Width, ModelKey, Context := "", Cache := "", ServerKey := "") {
        global SecondaryColor, TextColor, MutedColor
        global ContextPresets, KvCacheOptions

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

        this.ServerControl := GuiObj.AddDropDownList("x" X " y" Y " w" (Width - 98) " +0x210", [])
        ApplyDarkControl(this.ServerControl)

        GuiObj.SetFont("s11 c" TextColor, "Segoe UI")
        this.EditServerButton := GuiObj.AddButton("x+8 yp w26 h26", "…")
        this.AddServerButton := GuiObj.AddButton("x+6 yp w26 h26", "+")
        GuiObj.SetFont("s13 c" TextColor, "Segoe UI")
        this.DeleteServerButton := GuiObj.AddButton("x+6 yp w26 h26", "×")
        MakeOwnerDrawButton(this.EditServerButton)
        MakeOwnerDrawButton(this.AddServerButton)
        MakeOwnerDrawButton(this.DeleteServerButton)

        Y += 50
        GuiObj.SetFont("s12 Norm c" TextColor, "Segoe UI")
        GuiObj.AddText("x" X " y" Y, "Context")
        Y += 29

        this.ContextControl := GuiObj.AddComboBox(
            "x" X " y" Y " w" Width " +0x210 Background" SecondaryColor " c" TextColor,
            ContextPresets
        )
        ApplyDarkControl(this.ContextControl)

        Y += 50
        GuiObj.AddText("x" X " y" Y, "KV cache")
        Y += 29

        this.CacheControl := GuiObj.AddDropDownList(
            "x" X " y" Y " w" Width " +0x210",
            KvCacheOptions
        )
        ApplyDarkControl(this.CacheControl)

        Y += 50
        GuiObj.AddText("x" X " y" Y, "Model MCP directories")
        Y += 25

        GuiObj.SetFont("s10 c" MutedColor, "Segoe UI")
        GuiObj.AddText(
            "x" X " y" Y " w" (Width - 46),
            "Additional filesystem roots owned by this model."
        )
        Y += 25

        GuiObj.SetFont("s12 Norm c" TextColor, "Segoe UI")
        this.McpDirectoriesEdit := GuiObj.AddEdit(
            "x" X " y" Y " w" Width " r3 -VScroll Background" SecondaryColor " c" TextColor,
            ""
        )

        GuiObj.SetFont("s11 c" TextColor, "Segoe UI")
        this.McpBrowseButton := GuiObj.AddButton(
            "x" (X + Width - 36) " y" (Y - 32) " w34 h26",
            "…"
        )
        MakeOwnerDrawButton(this.McpBrowseButton)

        Y += 82
        GuiObj.SetFont("s10 c" MutedColor, "Segoe UI")
        this.DefaultsText := GuiObj.AddText("x" X " y" Y " w" Width " h38", "")
        this.Bottom := Y + 38

        this.ModelControl.OnEvent("Change", ObjBindMethod(this, "ResetToModelDefaults"))
        this.ServerControl.OnEvent("Change", ObjBindMethod(this, "UpdateServerButtons"))
        this.AddModelButton.OnEvent("Click", ObjBindMethod(this, "OpenAddModel"))
        this.DeleteModelButton.OnEvent("Click", ObjBindMethod(this, "DeleteSelectedModel"))
        this.EditServerButton.OnEvent("Click", ObjBindMethod(this, "EditSelectedServer"))
        this.AddServerButton.OnEvent("Click", ObjBindMethod(this, "AddServer"))
        this.DeleteServerButton.OnEvent("Click", ObjBindMethod(this, "DeleteSelectedServer"))
        this.McpBrowseButton.OnEvent(
            "Click",
            (*) => BrowseMcpDirectory(this.McpDirectoriesEdit)
        )

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
        this.McpBrowseButton.Enabled := HasModel

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
        this.UpdateServerButtons()
    }


    UpdateServerButtons(*) {
        global Servers

        ServerKey := this.GetServerKey()
        Registered := ServerKey != "" && Servers.Has(ServerKey)

        this.EditServerButton.Enabled := Registered
        this.DeleteServerButton.Enabled := Registered
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
                "At least one registered model must remain.",
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


    EditSelectedServer(*) {
        global Servers

        ServerKey := this.GetServerKey()
        if ServerKey = "" || !Servers.Has(ServerKey)
            return

        OpenServerEditor(
            this.Gui,
            ServerKey,
            ObjBindMethod(this, "ServerRegistryChanged")
        )
    }


    AddServer(*) {
        OpenServerEditor(
            this.Gui,
            "",
            ObjBindMethod(this, "ServerRegistryChanged")
        )
    }


    DeleteSelectedServer(*) {
        ServerKey := this.GetServerKey()
        if ServerKey = ""
            return

        if !ConfirmDeleteServer(ServerKey)
            return

        ; Preserve the deleted key in the selector as [Missing] when the
        ; current model/session still references it.
        this.RefreshServers(ServerKey)
        this.UpdateDefaultsText()
    }


    ServerRegistryChanged(ServerKey := "") {
        if ServerKey = ""
            ServerKey := this.GetServerKey()

        this.RefreshServers(ServerKey)
        this.UpdateDefaultsText()
    }
}

class McpConfigPanel {
    __New(GuiObj, X, Y, Width, Enabled, ProxyExecutable, Address, Port, Directories) {
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
        GuiObj.AddText("x" X " y" Y, "mcp-proxy executable")
        Y += 29

        this.ProxyExecutableEdit := GuiObj.AddEdit(
            "x" X " y" Y
            . " w" (Width - 42)
            . " r1 -Multi"
            . " Background" SecondaryColor
            . " c" TextColor,
            ProxyExecutable
        )

        GuiObj.SetFont("s11 c" TextColor, "Segoe UI")
        this.ProxyBrowseButton := GuiObj.AddButton(
            "x+8 yp w34 h26",
            "…"
        )
        MakeOwnerDrawButton(this.ProxyBrowseButton)

        Y += 50
        AddressWidth := Width - 124

        GuiObj.SetFont("s12 Norm c" TextColor, "Segoe UI")
        GuiObj.AddText("x" X " y" Y, "Bind address")
        GuiObj.AddText("x" (X + AddressWidth + 20) " yp", "Port")
        Y += 29

        this.AddressEdit := GuiObj.AddEdit(
            "x" X " y" Y
            . " w" AddressWidth
            . " r1 -Multi"
            . " Background" SecondaryColor
            . " c" TextColor,
            Address
        )

        this.PortEdit := GuiObj.AddEdit(
            "x" (X + AddressWidth + 20) " yp"
            . " w104"
            . " r1 -Multi"
            . " Background" SecondaryColor
            . " c" TextColor,
            Port
        )

        Y += 50
        GuiObj.AddText("x" X " y" Y, "Global MCP directories")
        Y += 25

        GuiObj.SetFont("s10 c" MutedColor, "Segoe UI")
        this.DirectoryHelp := GuiObj.AddText(
            "x" X " y" Y " w" (Width - 46),
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

        GuiObj.SetFont("s11 c" TextColor, "Segoe UI")
        this.DirectoryBrowseButton := GuiObj.AddButton(
            "x" (X + Width - 36) " y" (Y - 32) " w34 h26",
            "…"
        )
        MakeOwnerDrawButton(this.DirectoryBrowseButton)

        this.ProxyBrowseButton.OnEvent(
            "Click",
            (*) => BrowseMcpProxyExecutable(this.ProxyExecutableEdit)
        )

        this.DirectoryBrowseButton.OnEvent(
            "Click",
            (*) => BrowseMcpDirectory(this.DirectoryEdit)
        )

        this.Bottom := Y + 94

        this.SetValues(
            Enabled,
            ProxyExecutable,
            Address,
            Port,
            Directories
        )
    }


    SetValues(Enabled, ProxyExecutable, Address, Port, Directories) {
        this.EnabledControl.Choose(Enabled ? 1 : 2)
        this.ProxyExecutableEdit.Text := ProxyExecutable
        this.AddressEdit.Text := Address
        this.PortEdit.Text := Port
        this.SetDirectories(Directories)
    }


    GetValues() {
        Enabled := this.EnabledControl.Value = 1
        ProxyExecutable := Trim(this.ProxyExecutableEdit.Text)
        Address := Trim(this.AddressEdit.Text)
        Port := Trim(this.PortEdit.Text)
        Directories := this.GetDirectories()

        if Enabled && ProxyExecutable = "" {
            MsgBox(
                "Select the mcp-proxy executable while MCP is enabled.",
                "MCP Access",
                "Icon!"
            )

            return false
        }

        if ProxyExecutable != ""
        && !FileExist(ProxyExecutable) {
            MsgBox(
                "mcp-proxy executable not found:`n`n" ProxyExecutable,
                "MCP Access",
                "Icon!"
            )

            return false
        }

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
            ProxyExecutable: ProxyExecutable,
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
;  STARTUP SESSION CONFIGURATION
; ============================================================

OpenSessionConfig(*) {
    global MainGui

    ModelKey := GetMainSelectedModelKey()
    if ModelKey = ""
        return

    OpenModelConfigEditor(
        MainGui,
        ModelKey,
        "",
        "",
        "",
        "start"
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
    global AppWindowTitle

    ActiveGui := Gui(, AppWindowTitle)
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
        "WinLlama LLM"
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
        "xm+113 y+4 w407 h42",
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
        ""
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
    global ActiveGui
    global ActiveModelKey
    global ActiveServerKey
    global ActiveContext
    global ActiveCache

    OpenModelConfigEditor(
        ActiveGui,
        ActiveModelKey,
        ActiveContext,
        ActiveCache,
        ActiveServerKey,
        "apply"
    )
}


OpenModelConfigEditor(
    ParentGui,
    ModelKey,
    Context := "",
    Cache := "",
    ServerKey := "",
    ActionMode := "apply"
) {
    global BaseColor, TextColor

    IsStartMode := ActionMode = "start"
    IsSetupMode := ActionMode = "setup"

    EditorGui := Gui(
        ,
        IsStartMode
            ? "Configure Session"
            : IsSetupMode
                ? "WinLlama Setup - Model"
                : "Model Settings"
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
        IsStartMode
            ? "CONFIGURE SESSION"
            : IsSetupMode
                ? "MODEL CONFIGURATION"
                : "MODEL SETTINGS"
    )

    ModelPanel := ModelConfigPanel(
        EditorGui,
        24,
        70,
        480,
        ModelKey,
        Context,
        Cache,
        ServerKey
    )

    EditorGui.SetFont(
        "s12 c" TextColor,
        "Segoe UI"
    )

    if IsSetupMode {
        ContinueButton := EditorGui.AddButton(
            "x24 y" ModelPanel.Bottom + 22
            . " w230 h42",
            "Continue"
        )

        ExitButton := EditorGui.AddButton(
            "x274 yp w230 h42",
            "Exit"
        )

        MakeOwnerDrawButton(ContinueButton)
        MakeOwnerDrawButton(ExitButton)

        ContinueButton.OnEvent(
            "Click",
            (*) => ContinueSetupFromModel(
                EditorGui,
                ParentGui,
                ModelPanel
            )
        )

        ExitButton.OnEvent(
            "Click",
            (*) => ExitApp()
        )

        EditorGui.OnEvent(
            "Close",
            (*) => ExitApp()
        )
    }
    else {
        PrimaryButton := EditorGui.AddButton(
            "x24 y" ModelPanel.Bottom + 22
            . " w150 h42",
            IsStartMode ? "Start" : "Apply"
        )

        SaveDefaultsButton := EditorGui.AddButton(
            "x189 yp w150 h42",
            "Save Defaults"
        )

        CancelButton := EditorGui.AddButton(
            "x354 yp w150 h42",
            "Cancel"
        )

        MakeOwnerDrawButton(PrimaryButton)
        MakeOwnerDrawButton(SaveDefaultsButton)
        MakeOwnerDrawButton(CancelButton)

        if IsStartMode {
            PrimaryButton.OnEvent(
                "Click",
                (*) => StartModelSession(
                    EditorGui,
                    ParentGui,
                    ModelPanel
                )
            )
        }
        else {
            PrimaryButton.OnEvent(
                "Click",
                (*) => ApplyModelConfig(
                    EditorGui,
                    ModelPanel
                )
            )
        }

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
                ParentGui
            )
        )

        EditorGui.OnEvent(
            "Close",
            (*) => EndConfigDialog(
                EditorGui,
                ParentGui
            )
        )
    }

    ShowRelative(
        EditorGui,
        ParentGui
    )
}


StartModelSession(EditorGui, ParentGui, ModelPanel) {
    Values := ModelPanel.GetValues()

    if !Values
        return

    EndConfigDialog(
        EditorGui,
        ParentGui,
        false
    )

    EnterActiveView(
        Values.ModelKey,
        Values.Context,
        Values.Cache,
        Values.ServerKey,
        Values.McpDirectories
    )

    LaunchAI(
        Values.ModelKey,
        Values.Context,
        Values.Cache,
        Values.ServerKey
    )
}


ApplyModelConfig(EditorGui, ModelPanel) {
    global ActiveGui
    global ActiveModelKey
    global ActiveServerKey
    global ActiveServerConfig
    global ActiveContext
    global ActiveCache
    global ActiveModelMcpDirectories
    global LlamaPid
    global LlamaState
    global Models

    Values := ModelPanel.GetValues()

    if !Values
        return

    DesiredServer := CreateServerRuntimeConfig(
        Values.ServerKey
    )

    if !DesiredServer {
        MsgBox(
            "The selected model references an unregistered llama server:`n`n"
            . Values.ServerKey,
            "Model Settings",
            "Icon!"
        )

        return
    }

    ServerDefinitionChanged :=
        Values.ServerKey = ActiveServerKey
        && IsObject(ActiveServerConfig)
        && !SameServerRuntimeConfig(
            ActiveServerConfig,
            DesiredServer
        )

    LlamaChanged :=
        Values.ModelKey != ActiveModelKey
        || Values.ServerKey != ActiveServerKey
        || Values.Context != ActiveContext
        || Values.Cache != ActiveCache
        || ServerDefinitionChanged

    McpRootsChanged := !SameDirectories(
        Values.McpDirectories,
        ActiveModelMcpDirectories
    )

    StartNeeded :=
        LlamaState = "offline"
        && (!LlamaPid || !ProcessExist(LlamaPid))

    if !LlamaChanged
    && !McpRootsChanged
    && !StartNeeded {
        EndConfigDialog(
            EditorGui,
            ActiveGui
        )
        return
    }

    if (LlamaChanged || StartNeeded)
    && !FileExist(DesiredServer.Executable) {
        MsgBox(
            "Llama server executable not found:`n`n"
            . DesiredServer.Executable,
            "Model Settings",
            "Icon!"
        )

        return
    }

    if (LlamaChanged || StartNeeded)
    && Models.Has(Values.ModelKey)
    && !FileExist(Models[Values.ModelKey].Model) {
        MsgBox(
            "Model not found:`n`n"
            . Models[Values.ModelKey].Model,
            "Model Settings",
            "Icon!"
        )

        return
    }

    OldHealthURL := ""
    Status := 0
    Owned :=
        LlamaPid
        && ProcessExist(LlamaPid)

    ; When changing an active llama configuration, probe the endpoint the
    ; current session actually uses — not the mutable server registry entry.
    if LlamaChanged && !StartNeeded {
        OldHealthURL := GetServerHealthURL(
            ActiveServerConfig
        )

        Status :=
            OldHealthURL != ""
                ? HttpStatus(OldHealthURL)
                : 0

        if Status != 0 && !Owned {
            MsgBox(
                "The active llama-server was not started by this controller.`n`n"
                . "Its configuration cannot be changed safely.",
                "Model Settings",
                "Icon!"
            )

            return
        }
    }

    ActiveModelKey := Values.ModelKey
    ActiveServerKey := Values.ServerKey
    ActiveContext := Values.Context
    ActiveCache := Values.Cache
    ActiveModelMcpDirectories := Values.McpDirectories

    SyncMainModelSelection(
        ActiveModelKey
    )

    EndConfigDialog(
        EditorGui,
        ActiveGui
    )

    if LlamaChanged && Owned {
        RestartLlamaWithOfflineURL(
            OldHealthURL
        )
    }
    else if LlamaChanged || StartNeeded {
        StartActiveLlama()
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
    NameEdit := DialogGui.AddEdit("x24 y99 w480 r1 -Multi Background" SecondaryColor " c" TextColor, "")

    DialogGui.AddText("x24 y145", "GGUF model")
    ModelPathEdit := DialogGui.AddEdit("x24 y174 w438 r1 -Multi Background" SecondaryColor " c" TextColor, "")

    DialogGui.SetFont("s11 c" TextColor, "Segoe UI")
    BrowseButton := DialogGui.AddButton("x470 y173 w34 h26", "…")
    MakeOwnerDrawButton(BrowseButton)

    DialogGui.SetFont("s12 Norm c" TextColor, "Segoe UI")
    DialogGui.AddText("x24 y220", "Llama server")
    ServerControl := DialogGui.AddDropDownList("x24 y249 w382 +0x210", [])
    ApplyDarkControl(ServerControl)

    DialogGui.SetFont("s11 c" TextColor, "Segoe UI")
    EditServerButton := DialogGui.AddButton("x414 yp w26 h26", "…")
    AddServerButton := DialogGui.AddButton("x446 yp w26 h26", "+")
    DialogGui.SetFont("s13 c" TextColor, "Segoe UI")
    DeleteServerButton := DialogGui.AddButton("x478 yp w26 h26", "×")
    MakeOwnerDrawButton(EditServerButton)
    MakeOwnerDrawButton(AddServerButton)
    MakeOwnerDrawButton(DeleteServerButton)

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
        ServerKeys: [],
        EditServerButton: EditServerButton,
        DeleteServerButton: DeleteServerButton
    }

    BrowseButton.OnEvent("Click", (*) => BrowseModelFile(ModelPathEdit))
    ServerControl.OnEvent("Change", UpdateAddModelServerButtons)
    EditServerButton.OnEvent("Click", EditAddModelServer)
    AddServerButton.OnEvent("Click", AddAddModelServer)
    DeleteServerButton.OnEvent("Click", DeleteAddModelServer)
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
    UpdateAddModelServerButtons()
}


UpdateAddModelServerButtons(*) {
    global ModelRegistrationState
    global Servers

    if !IsObject(ModelRegistrationState)
        return

    ServerKey := GetAddModelServerKey()
    Registered := ServerKey != "" && Servers.Has(ServerKey)

    ModelRegistrationState.EditServerButton.Enabled := Registered
    ModelRegistrationState.DeleteServerButton.Enabled := Registered
}


EditAddModelServer(*) {
    global ModelRegistrationState
    global Servers

    ServerKey := GetAddModelServerKey()
    if ServerKey = "" || !Servers.Has(ServerKey)
        return

    OpenServerEditor(
        ModelRegistrationState.Gui,
        ServerKey,
        RefreshAddModelServers
    )
}


AddAddModelServer(*) {
    global ModelRegistrationState

    OpenServerEditor(
        ModelRegistrationState.Gui,
        "",
        RefreshAddModelServers
    )
}


DeleteAddModelServer(*) {
    ServerKey := GetAddModelServerKey()
    if ServerKey = ""
        return

    if !ConfirmDeleteServer(ServerKey)
        return

    RefreshAddModelServers()
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


OpenMcpConfigEditor(ParentGui, AllowApply := false, SetupMode := false) {
    global McpEnabled, McpProxyExecutable, McpAddress, McpPort
    global McpDirectories, McpProxyAutoDiscovered
    global BaseColor, TextColor

    EditorGui := Gui(
        ,
        SetupMode
            ? "WinLlama Setup - MCP"
            : "MCP Access"
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
        SetupMode
            ? "MCP ACCESS (OPTIONAL)"
            : "MCP ACCESS"
    )

    PanelMcpEnabled := McpEnabled

    if SetupMode && McpProxyAutoDiscovered
        PanelMcpEnabled := true

    McpPanel := McpConfigPanel(
        EditorGui,
        24,
        70,
        480,
        PanelMcpEnabled,
        McpProxyExecutable,
        McpAddress,
        McpPort,
        McpDirectories
    )

    EditorGui.SetFont(
        "s12 c" TextColor,
        "Segoe UI"
    )

    if SetupMode {
        SaveButton := EditorGui.AddButton(
            "x24 y" McpPanel.Bottom + 22
            . " w230 h42",
            "Save & Continue"
        )

        SkipButton := EditorGui.AddButton(
            "x274 yp w230 h42",
            "Skip"
        )

        MakeOwnerDrawButton(SaveButton)
        MakeOwnerDrawButton(SkipButton)

        SaveButton.OnEvent(
            "Click",
            (*) => SaveSetupMcpAndContinue(
                EditorGui,
                ParentGui,
                McpPanel
            )
        )

        SkipButton.OnEvent(
            "Click",
            (*) => SkipSetupMcp(
                EditorGui,
                ParentGui
            )
        )

        EditorGui.OnEvent(
            "Close",
            (*) => ExitApp()
        )
    }
    else if AllowApply {
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

        CancelButton.OnEvent(
            "Click",
            (*) => EndConfigDialog(
                EditorGui,
                ParentGui
            )
        )

        EditorGui.OnEvent(
            "Close",
            (*) => EndConfigDialog(
                EditorGui,
                ParentGui
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

        CancelButton.OnEvent(
            "Click",
            (*) => EndConfigDialog(
                EditorGui,
                ParentGui
            )
        )

        EditorGui.OnEvent(
            "Close",
            (*) => EndConfigDialog(
                EditorGui,
                ParentGui
            )
        )
    }

    ShowRelative(
        EditorGui,
        ParentGui
    )
}


SaveMcpEditorConfig(McpPanel) {
    Values := McpPanel.GetValues()

    if !Values
        return false

    if Values.Directories != ""
    && !VerifyDirectories(Values.Directories)
        return false

    SaveMcpDefaults(
        Values.Enabled,
        Values.ProxyExecutable,
        Values.Address,
        Values.Port,
        Values.Directories
    )

    UpdateMainModelInfo()

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
;  CAPTURED PROCESS / SESSION LOGGING
; ============================================================

BeginLogSession(Service) {
    global LogsDirectory
    global LlamaLogSessions, McpLogSessions
    global LogStreams
    global LlamaLog, McpLog
    global ConsoleLlamaText, ConsoleMcpText
    global ConsoleLlamaRevision, ConsoleMcpRevision
    global McpPollState

    SessionCount := Service = "llama"
        ? LlamaLogSessions
        : McpLogSessions

    SlotKey := Service = "llama"
        ? "LlamaLogSlot"
        : "McpLogSlot"

    Slot := ConfigReadInteger(
        "State",
        SlotKey,
        0
    ) + 1

    if Slot < 1
    || Slot > SessionCount
        Slot := 1

    ConfigWrite(
        "State",
        SlotKey,
        Slot
    )

    FilePath := LogsDirectory
        . "\"
        . Service
        . "-"
        . Format("{:02}", Slot)
        . ".log"

    try {
        File := FileOpen(
            FilePath,
            "w",
            "UTF-8-RAW"
        )

        if IsObject(File)
            File.Close()
        else
            FilePath := ""
    }
    catch {
        FilePath := ""
    }

    LogStreams[Service] := {
        FilePath: FilePath,
        Buffer: "",
        Dirty: false
    }

    if Service = "llama" {
        LlamaLog := FilePath
        ConsoleLlamaText := ""
        ConsoleLlamaRevision += 1
    }
    else {
        McpLog := FilePath
        ConsoleMcpText := ""
        ConsoleMcpRevision += 1

        McpPollState := {
            Active: false,
            Additional: 0,
            LatestRaw: "",
            LatestDisplay: "",
            ViewerTallyStart: 0
        }
    }

    UpdateConsoleLogs()
}

QueueLogFile(
    Service,
    Text,
    FlushNow := false
) {
    global LogStreams

    if Text = ""
        return

    Stream := LogStreams[Service]

    if Stream.FilePath = ""
        return

    Stream.Buffer .= Text
    Stream.Dirty := true

    if FlushNow
        FlushLogService(Service)
}

FlushDirtyLogs(*) {
    FlushLogService("llama")
    FlushLogService("mcp")
}

FlushLogService(Service) {
    global LogStreams

    Stream := LogStreams[Service]

    if !Stream.Dirty
    || Stream.Buffer = ""
        return true

    if Stream.FilePath = "" {
        Stream.Buffer := ""
        Stream.Dirty := false
        return false
    }

    ; Detach this batch from the live buffer before touching disk.
    ; New pipe activity can safely accumulate behind it.
    Text := Stream.Buffer
    Stream.Buffer := ""
    Stream.Dirty := false

    try {
        File := FileOpen(
            Stream.FilePath,
            "a",
            "UTF-8-RAW"
        )

        if !IsObject(File)
            throw Error("Could not open log file.")

        File.Write(
            Text
        )

        File.Close()
        return true
    }
    catch {
        ; Put the failed older batch back in front of anything newer.
        Stream.Buffer := Text . Stream.Buffer
        Stream.Dirty := true
        return false
    }
}

StartCapturedProcess(
    Service,
    Executable,
    CommandLine,
    WorkingDirectory
) {
    global CapturedProcesses

    SaSize := A_PtrSize = 8
        ? 24
        : 12

    SaInheritOffset := A_PtrSize = 8
        ? 16
        : 8

    Security := Buffer(
        SaSize,
        0
    )

    NumPut(
        "UInt",
        SaSize,
        Security,
        0
    )

    NumPut(
        "Int",
        1,
        Security,
        SaInheritOffset
    )

    ReadBuffer := Buffer(
        A_PtrSize,
        0
    )

    WriteBuffer := Buffer(
        A_PtrSize,
        0
    )

    if !DllCall(
        "Kernel32\CreatePipe",
        "ptr", ReadBuffer.Ptr,
        "ptr", WriteBuffer.Ptr,
        "ptr", Security.Ptr,
        "uint", 1048576,
        "int"
    )
        throw Error(
            "Could not create the process output pipe. Windows error "
            . DllCall("Kernel32\GetLastError", "uint")
            . "."
        )

    ReadHandle := NumGet(
        ReadBuffer,
        0,
        "Ptr"
    )

    WriteHandle := NumGet(
        WriteBuffer,
        0,
        "Ptr"
    )

    NulHandle := 0

    try {
        ; The controller's read end must remain private to the parent.
        if !DllCall(
            "Kernel32\SetHandleInformation",
            "ptr", ReadHandle,
            "uint", 0x1,
            "uint", 0,
            "int"
        )
            throw Error(
                "Could not protect the process output pipe from inheritance."
            )

        NulHandle := DllCall(
            "Kernel32\CreateFileW",
            "wstr", "NUL",
            "uint", 0x80000000,
            "uint", 0x3,
            "ptr", Security.Ptr,
            "uint", 3,
            "uint", 0x80,
            "ptr", 0,
            "ptr"
        )

        if NulHandle = -1
            throw Error(
                "Could not open the null input device for the child process."
            )

        SiSize := A_PtrSize = 8
            ? 104
            : 68

        FlagsOffset := A_PtrSize = 8
            ? 60
            : 44

        StdInputOffset := A_PtrSize = 8
            ? 80
            : 56

        StdOutputOffset := StdInputOffset
            + A_PtrSize

        StdErrorOffset := StdOutputOffset
            + A_PtrSize

        StartupInfo := Buffer(
            SiSize,
            0
        )

        NumPut(
            "UInt",
            SiSize,
            StartupInfo,
            0
        )

        NumPut(
            "UInt",
            0x100,  ; STARTF_USESTDHANDLES
            StartupInfo,
            FlagsOffset
        )

        NumPut(
            "Ptr",
            NulHandle,
            StartupInfo,
            StdInputOffset
        )

        NumPut(
            "Ptr",
            WriteHandle,
            StartupInfo,
            StdOutputOffset
        )

        NumPut(
            "Ptr",
            WriteHandle,
            StartupInfo,
            StdErrorOffset
        )

        ProcessInfo := Buffer(
            A_PtrSize * 2 + 8,
            0
        )

        CommandBuffer := Buffer(
            StrPut(
                CommandLine,
                "UTF-16"
            ) * 2,
            0
        )

        StrPut(
            CommandLine,
            CommandBuffer,
            "UTF-16"
        )

        Success := DllCall(
            "Kernel32\CreateProcessW",
            "wstr", Executable,
            "ptr", CommandBuffer.Ptr,
            "ptr", 0,
            "ptr", 0,
            "int", true,
            "uint", 0x08000000,  ; CREATE_NO_WINDOW
            "ptr", 0,
            "wstr", WorkingDirectory,
            "ptr", StartupInfo.Ptr,
            "ptr", ProcessInfo.Ptr,
            "int"
        )

        if !Success
            throw Error(
                "Could not start the process. Windows error "
                . DllCall("Kernel32\GetLastError", "uint")
                . "."
            )

        ProcessHandle := NumGet(
            ProcessInfo,
            0,
            "Ptr"
        )

        ThreadHandle := NumGet(
            ProcessInfo,
            A_PtrSize,
            "Ptr"
        )

        Pid := NumGet(
            ProcessInfo,
            A_PtrSize * 2,
            "UInt"
        )

        CloseWinHandle(
            ProcessHandle
        )

        CloseWinHandle(
            ThreadHandle
        )
    }
    catch Error as Err {
        CloseWinHandle(
            ReadHandle
        )

        CloseWinHandle(
            WriteHandle
        )

        CloseWinHandle(
            NulHandle
        )

        throw Err
    }

    ; Parent keeps only the read end after process creation.
    CloseWinHandle(
        WriteHandle
    )

    CloseWinHandle(
        NulHandle
    )

    if CapturedProcesses.Has(Service)
        FinalizeCapturedProcess(
            Service
        )

    BeginLogSession(
        Service
    )

    CapturedProcesses[Service] := {
        Pid: Pid,
        ReadHandle: ReadHandle,
        Partial: "",
        Utf8Tail: []
    }

    ; Drain anything emitted during process creation immediately.
    PollCapturedProcesses()

    return Pid
}

CloseWinHandle(Handle) {
    if !Handle
    || Handle = -1
        return

    DllCall(
        "Kernel32\CloseHandle",
        "ptr", Handle
    )
}

PollCapturedProcesses(*) {
    global CapturedProcesses


    for Service in ["llama", "mcp"] {
        if !CapturedProcesses.Has(Service)
            continue

        State := CapturedProcesses[Service]

        DrainCapturedPipe(
            Service,
            State
        )

        if !ProcessExist(State.Pid) {
            ; Process termination may have left a final burst buffered.
            DrainCapturedPipe(
                Service,
                State
            )

            FinalizeCapturedProcess(
                Service
            )
        }
    }
}

DrainCapturedPipe(
    Service,
    State
) {
    if !State.ReadHandle
        return false

    AvailableBuffer := Buffer(
        4,
        0
    )

    while true {
        Success := DllCall(
            "Kernel32\PeekNamedPipe",
            "ptr", State.ReadHandle,
            "ptr", 0,
            "uint", 0,
            "ptr", 0,
            "ptr", AvailableBuffer.Ptr,
            "ptr", 0,
            "int"
        )

        if !Success
            return false

        Available := NumGet(
            AvailableBuffer,
            0,
            "UInt"
        )

        if !Available
            return true

        ReadSize := Min(
            Available,
            65536
        )

        Data := Buffer(
            ReadSize,
            0
        )

        BytesReadBuffer := Buffer(
            4,
            0
        )

        if !DllCall(
            "Kernel32\ReadFile",
            "ptr", State.ReadHandle,
            "ptr", Data.Ptr,
            "uint", ReadSize,
            "ptr", BytesReadBuffer.Ptr,
            "ptr", 0,
            "int"
        )
            return false

        BytesRead := NumGet(
            BytesReadBuffer,
            0,
            "UInt"
        )

        if !BytesRead
            return true

        Text := DecodeCapturedUtf8(
            State,
            Data,
            BytesRead
        )

        if Text != ""
            ProcessCapturedText(
                Service,
                State,
                Text
            )
    }
}

DecodeCapturedUtf8(
    State,
    Data,
    Length
) {
    TailLength := State.Utf8Tail.Length
    TotalLength := TailLength + Length

    Combined := Buffer(
        TotalLength,
        0
    )

    for Index, Byte in State.Utf8Tail {
        NumPut(
            "UChar",
            Byte,
            Combined,
            Index - 1
        )
    }

    if Length {
        DllCall(
            "Kernel32\RtlMoveMemory",
            "ptr", Combined.Ptr + TailLength,
            "ptr", Data.Ptr,
            "uptr", Length
        )
    }

    CompleteLength := GetCompleteUtf8PrefixLength(
        Combined,
        TotalLength
    )

    State.Utf8Tail := []

    Loop TotalLength - CompleteLength {
        State.Utf8Tail.Push(
            NumGet(
                Combined,
                CompleteLength + A_Index - 1,
                "UChar"
            )
        )
    }

    if !CompleteLength
        return ""

    return StrGet(
        Combined.Ptr,
        CompleteLength,
        "UTF-8"
    )
}

GetCompleteUtf8PrefixLength(
    Data,
    Length
) {
    if Length <= 0
        return 0

    Index := Length - 1

    while Index >= 0 {
        Byte := NumGet(
            Data,
            Index,
            "UChar"
        )

        if (Byte & 0xC0) != 0x80
            break

        Index -= 1
    }

    if Index < 0
        return Length

    Lead := NumGet(
        Data,
        Index,
        "UChar"
    )

    if Lead < 0x80
        Expected := 1
    else if Lead >= 0xC2
    && Lead <= 0xDF
        Expected := 2
    else if Lead >= 0xE0
    && Lead <= 0xEF
        Expected := 3
    else if Lead >= 0xF0
    && Lead <= 0xF4
        Expected := 4
    else
        return Length

    Actual := Length - Index

    return Actual < Expected
        ? Index
        : Length
}

ProcessCapturedText(
    Service,
    State,
    Text
) {
    State.Partial .= Text

    while Newline := InStr(
        State.Partial,
        "`n"
    ) {
        Record := SubStr(
            State.Partial,
            1,
            Newline
        )

        State.Partial := SubStr(
            State.Partial,
            Newline + 1
        )

        ProcessCapturedRecord(
            Service,
            Record
        )
    }
}

ProcessCapturedRecord(
    Service,
    RawRecord
) {
    DisplayRecord := StripAnsi(
        RawRecord
    )

    if Service = "mcp" {
        if IsMcpPollingRecord(
            DisplayRecord
        ) {
            ProcessMcpPollingRecord(
                RawRecord,
                DisplayRecord
            )

            return
        }

        FinalizeMcpPollingTally()
    }

    QueueLogFile(
        Service,
        RawRecord
    )

    AppendLogViewerText(
        Service,
        DisplayRecord
    )
}

AppendLogViewerText(
    Service,
    Text
) {
    global ConsoleLlamaText, ConsoleMcpText
    global ConsoleLlamaRevision, ConsoleMcpRevision

    if Service = "llama" {
        ConsoleLlamaText .= Text
        ConsoleLlamaRevision += 1
    }
    else {
        ConsoleMcpText .= Text
        ConsoleMcpRevision += 1
    }
}

IsMcpPollingRecord(Text) {
    Clean := Trim(
        Text,
        "`r`n"
    )

    return RegExMatch(
        Clean,
        '^INFO:\s+\S+:\d+\s+-\s+"GET /status HTTP/1\.1"\s+200 OK$'
    )
}

ProcessMcpPollingRecord(
    RawRecord,
    DisplayRecord
) {
    global McpPollState
    global ConsoleMcpText
    global ConsoleMcpRevision

    if !McpPollState.Active {
        McpPollState.Active := true
        McpPollState.Additional := 0
        McpPollState.LatestRaw := RawRecord
        McpPollState.LatestDisplay := DisplayRecord
        McpPollState.ViewerTallyStart := 0

        ; Persist the first poll immediately. If WinLlama crashes during
        ; a long idle run, the log still proves MCP was recently healthy.
        QueueLogFile(
            "mcp",
            RawRecord,
            true
        )

        ConsoleMcpText .= DisplayRecord
        ConsoleMcpRevision += 1
        return
    }

    McpPollState.Additional += 1
    McpPollState.LatestRaw := RawRecord
    McpPollState.LatestDisplay := DisplayRecord

    Tally := AddPollingMultiplier(
        DisplayRecord,
        McpPollState.Additional
    )

    if McpPollState.Additional = 1 {
        McpPollState.ViewerTallyStart :=
            StrLen(ConsoleMcpText) + 1

        ConsoleMcpText .= Tally
        ConsoleMcpRevision += 1
        return
    }

    ConsoleMcpText := SubStr(
        ConsoleMcpText,
        1,
        McpPollState.ViewerTallyStart - 1
    ) . Tally

    ConsoleMcpRevision += 1
}

FinalizeMcpPollingTally() {
    global McpPollState

    if !McpPollState.Active
        return

    if McpPollState.Additional > 0 {
        QueueLogFile(
            "mcp",
            AddPollingMultiplier(
                McpPollState.LatestRaw,
                McpPollState.Additional
            )
        )
    }

    McpPollState.Active := false
    McpPollState.Additional := 0
    McpPollState.LatestRaw := ""
    McpPollState.LatestDisplay := ""
    McpPollState.ViewerTallyStart := 0
}

AddPollingMultiplier(
    Text,
    Count
) {
    Ending := ""
    Body := Text

    if SubStr(Body, -1) = "`n" {
        Ending := "`n"
        Body := SubStr(
            Body,
            1,
            -1
        )

        if SubStr(Body, -1) = "`r" {
            Ending := "`r`n"
            Body := SubStr(
                Body,
                1,
                -1
            )
        }
    }

    return Body
        . " (x"
        . Count
        . ")"
        . Ending
}

FinalizeCapturedProcess(Service) {
    global CapturedProcesses

    if !CapturedProcesses.Has(Service)
        return

    State := CapturedProcesses[Service]

    DrainCapturedPipe(
        Service,
        State
    )

    if State.Utf8Tail.Length {
        Tail := Buffer(
            State.Utf8Tail.Length,
            0
        )

        for Index, Byte in State.Utf8Tail {
            NumPut(
                "UChar",
                Byte,
                Tail,
                Index - 1
            )
        }

        State.Partial .= StrGet(
            Tail.Ptr,
            Tail.Size,
            "UTF-8"
        )

        State.Utf8Tail := []
    }

    if State.Partial != "" {
        ProcessCapturedRecord(
            Service,
            State.Partial
        )

        State.Partial := ""
    }

    if Service = "mcp"
        FinalizeMcpPollingTally()

    CloseWinHandle(
        State.ReadHandle
    )

    CapturedProcesses.Delete(
        Service
    )

    ; A normal stop/restart should leave a complete session on disk.
    FlushLogService(
        Service
    )

    UpdateConsoleLogs()
}

FinalizeCapturedProcessByPid(Pid) {
    global CapturedProcesses

    for Service in ["llama", "mcp"] {
        if CapturedProcesses.Has(Service)
        && CapturedProcesses[Service].Pid = Pid {
            FinalizeCapturedProcess(
                Service
            )

            return
        }
    }
}

FinalizeAllCapturedProcesses() {
    global CapturedProcesses

    for Service in ["llama", "mcp"] {
        if CapturedProcesses.Has(Service)
            FinalizeCapturedProcess(
                Service
            )
    }

    FlushDirtyLogs()
}

; ============================================================
;  CONSOLE VIEWER
; ============================================================

OpenConsoleViewer(*) {
    global ConsoleGui
    global ConsoleActiveTab

    global ConsoleLlamaText
    global ConsoleMcpText
    global ConsoleRenderedText
    global ConsoleRenderedRevision

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
    global ConsoleOutputNoWrap
    global ConsoleOutputWrap

    global ActiveGui

    global BaseColor
    global SecondaryColor
    global TextColor
    global MutedColor
    global AppName


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

    ConsoleRenderedText := ""
    ConsoleRenderedRevision := -1
	
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
        AppName " - Consoles"
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

	ConsoleOutputNoWrap := ConsoleGui.AddEdit(
		"x22 y54 w900 r30 ReadOnly -VScroll -Wrap Background"
		. SecondaryColor
		. " c"
		. TextColor,
		""
	)

	ConsoleOutputWrap := ConsoleGui.AddEdit(
		"x22 y54 w900 r30 ReadOnly -VScroll +Wrap Background"
		. SecondaryColor
		. " c"
		. TextColor,
		""
	)

	if ConsoleWrapEnabled {
		ConsoleOutput := ConsoleOutputWrap
		ConsoleOutputNoWrap.Visible := false
	}
	else {
		ConsoleOutput := ConsoleOutputNoWrap
		ConsoleOutputWrap.Visible := false
	}


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

    ; Render the current in-memory sessions immediately.
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
    global ConsoleRenderedText
    global ConsoleRenderedRevision

    global ConsoleLlamaText
    global ConsoleMcpText
    global ConsoleLlamaRevision, ConsoleMcpRevision

    if ConsoleActiveTab = Tab
        return

    ConsoleActiveTab := Tab

    Text := Tab = "llama"
        ? ConsoleLlamaText
        : ConsoleMcpText

    ConsoleOutput.Value := Text
    ConsoleRenderedText := Text
    ConsoleRenderedRevision := Tab = "llama"
        ? ConsoleLlamaRevision
        : ConsoleMcpRevision

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
    global ConsoleOutput
    global ConsoleOutputNoWrap
    global ConsoleOutputWrap
    global ConsoleWrapEnabled
    global ConsoleActiveTab
    global ConsoleRenderedText
    global ConsoleRenderedRevision

    global ConsoleLlamaText
    global ConsoleMcpText
    global ConsoleLlamaRevision, ConsoleMcpRevision


    Text :=
        ConsoleActiveTab = "llama"
        ? ConsoleLlamaText
        : ConsoleMcpText

    OldOutput := ConsoleOutput

    ConsoleOutput :=
        ConsoleWrapEnabled
        ? ConsoleOutputWrap
        : ConsoleOutputNoWrap

    ConsoleOutput.Value := Text
    ConsoleRenderedText := Text
    ConsoleRenderedRevision := ConsoleActiveTab = "llama"
        ? ConsoleLlamaRevision
        : ConsoleMcpRevision

    if IsObject(OldOutput)
        OldOutput.Visible := false

    ConsoleOutput.Visible := true

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
    global ConsoleGui
    global ConsoleActiveTab
    global ConsoleRenderedText
    global ConsoleRenderedRevision
    global ConsoleLlamaText, ConsoleMcpText
    global ConsoleLlamaRevision, ConsoleMcpRevision

    if !IsObject(ConsoleGui)
        return

    if ConsoleActiveTab = "llama" {
        Text := ConsoleLlamaText
        Revision := ConsoleLlamaRevision
    }
    else {
        Text := ConsoleMcpText
        Revision := ConsoleMcpRevision
    }

    if Revision = ConsoleRenderedRevision
        return

    RenderedLength := StrLen(
        ConsoleRenderedText
    )

    ; Most updates are append-only. Preserve the existing fast append
    ; path and its tail-follow behavior whenever possible.
    if RenderedLength <= StrLen(Text)
    && SubStr(
        Text,
        1,
        RenderedLength
    ) = ConsoleRenderedText {
        AppendConsoleText(
            SubStr(
                Text,
                RenderedLength + 1
            )
        )
    }
    else {
        ; MCP's polling tally rewrites its final display line. A full
        ; replacement is rare and preserves the reader's viewport.
        ReplaceConsoleText(
            Text
        )
    }

    ConsoleRenderedText := Text
    ConsoleRenderedRevision := Revision
}


ReplaceConsoleText(Text) {
    global ConsoleOutput

    static EM_GETFIRSTVISIBLELINE := 0x00CE
    static EM_LINESCROLL := 0x00B6

    FollowTail := ConsoleIsAtBottom()

    if !FollowTail {
        FirstVisibleBefore := DllCall(
            "user32\SendMessageW",
            "ptr", ConsoleOutput.Hwnd,
            "uint", EM_GETFIRSTVISIBLELINE,
            "ptr", 0,
            "ptr", 0
        )
    }

    ConsoleOutput.Value := Text

    if FollowTail {
        ScrollConsoleToBottom()
        return
    }

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

    FinalizeCapturedProcessByPid(
        Pid
    )
}


; ============================================================
;  LAUNCH
; ============================================================

LaunchAI(ModelKey, ContextOverride, CacheOverride, ServerKeyOverride := "") {
	global Models
    global McpStartupUntil, McpStartupGrace
    global McpProbeSuppressed
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

        ReturnToStartup()
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

        ReturnToStartup()
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

    if DesiredMcp.Enabled {
        ; Preserve startup intent across the Start -> Active handoff.
        ; EnterActiveView already establishes grace, but LaunchAI used to
        ; clear it before StartMcp had a chance to refresh the deadline.
        McpStartupUntil :=
            A_TickCount
            + McpStartupGrace

        McpProbeSuppressed := false
        McpURL := GetMcpStatusURL(
            DesiredMcp
        )

        if HttpStatus(McpURL) != 0 {
            McpStartupUntil := 0

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
                McpStartupUntil := 0
                McpProbeSuppressed := true

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
                        McpStartupGrace
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
                    McpProbeSuppressed := true

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
    else {
        McpStartupUntil := 0
        McpProbeSuppressed := true
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

    ProxyExecutable := Trim(Config.ProxyExecutable)

    if ProxyExecutable = ""
        throw Error("mcp-proxy executable is not configured.")

    if !FileExist(ProxyExecutable)
        throw Error("mcp-proxy executable not found: " ProxyExecutable)

    McpCommand :=
        '"' ProxyExecutable '" '
        . "--host " Host " "
        . "--port " Config.Port " "
        . "--transport streamablehttp "
        . "-- "
        . "mcp-server-filesystem"
        . DirectoryArgs

    McpStartupUntil :=
        A_TickCount
        + McpStartupGrace

    McpPid := StartCapturedProcess(
        "mcp",
        ProxyExecutable,
        McpCommand,
        A_ScriptDir
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

    LlamaPid := StartCapturedProcess(
        "llama",
        Server.Executable,
        ServerCommand,
        GetParentDirectory(
            Server.Executable
        )
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
    global ActiveServerConfig
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
    global LlamaProbeSuppressed


    InStartupGrace :=
        LlamaStartupUntil
        && A_TickCount < LlamaStartupUntil

    ; A wrapper PID may not be observable immediately during process startup.
    ; Never let that transient race cancel an active startup grace window.
    if LlamaPid
    && !ProcessExist(LlamaPid) {
        LlamaPid := 0

        if !InStartupGrace
            LlamaProbeSuppressed := true
    }


    if !Models.Has(
        ActiveModelKey
    )
        return true


    Model :=
        Models[ActiveModelKey]

    Server := ActiveServerConfig


    ; --------------------------------------------------------
    ;  NO ACTIVE SERVER SNAPSHOT
    ; --------------------------------------------------------

    if !IsObject(Server) {
        LlamaStartupUntil := 0
        LlamaState := "offline"
        LlamaProbeSuppressed := true

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


    Owned :=
        LlamaPid
        && ProcessExist(LlamaPid)


    ; --------------------------------------------------------
    ;  KNOWN OFFLINE — NO AUTOMATIC HTTP PROBE
    ; --------------------------------------------------------

    if LlamaProbeSuppressed
    && !Owned
    && !InStartupGrace {
        LlamaStartupUntil := 0
        LlamaState := "offline"

        ActiveLlamaStatus.Text := "○ Offline"
        ActiveLlamaName.Text := Model.Name
        ActiveLlamaDetails.Text := GetActiveLlamaDetails()

        ActiveLlamaEditButton.Enabled := true
        ActiveLlamaStartButton.Enabled := true
        ActiveLlamaRestartButton.Enabled := false
        ActiveLlamaStopButton.Enabled := false

        return true
    }


    HealthURL := GetServerHealthURL(
        Server
    )

    Status :=
        HttpStatus(
            HealthURL
        )


    if Status = 200
        LlamaStartupUntil := 0


    ; --------------------------------------------------------
    ;  STARTUP GRACE
    ; --------------------------------------------------------

    if Status != 200
    && A_TickCount < LlamaStartupUntil {
        LlamaState := "loading"
        LlamaProbeSuppressed := false

        ActiveLlamaStatus.Text := "◐ Loading"
        ActiveLlamaStartButton.Enabled := false
        ActiveLlamaRestartButton.Enabled := false
        ActiveLlamaStopButton.Enabled := Owned

        return false
    }


    ; --------------------------------------------------------
    ;  OFFLINE
    ; --------------------------------------------------------

    if Status = 0 {
        LlamaStartupUntil := 0
        LlamaState := "offline"
        LlamaProbeSuppressed := true

        ActiveLlamaStatus.Text :=
            "○ Offline"

        ActiveLlamaName.Text :=
            Model.Name

        ActiveLlamaDetails.Text := GetActiveLlamaDetails()

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
        LlamaProbeSuppressed := false

        if Status = 503
            ActiveLlamaStatus.Text :=
                "◐ External"
        else
            ActiveLlamaStatus.Text :=
                "● External"

        ActiveLlamaName.Text :=
            "Existing llama-server"

        ActiveLlamaDetails.Text :=
            GetActiveLlamaDetails()
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

    LlamaProbeSuppressed := false

    ActiveLlamaName.Text :=
        Model.Name

    ActiveLlamaDetails.Text := GetActiveLlamaDetails()


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
        ActiveLlamaRestartButton.Enabled :=
            GetServer(ActiveServerKey)
                ? true
                : false
        ActiveLlamaStopButton.Enabled := true

        return true
    }

    else {
        LlamaState := "error"

        ActiveLlamaStatus.Text :=
            "! HTTP "
            . Status

        ActiveLlamaStartButton.Enabled := false
        ActiveLlamaRestartButton.Enabled :=
            GetServer(ActiveServerKey)
                ? true
                : false
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
    global McpProbeSuppressed


    InStartupGrace :=
        McpStartupUntil
        && A_TickCount < McpStartupUntil

    if McpPid
    && !ProcessExist(McpPid) {
        McpPid := 0

        if !InStartupGrace {
            McpProbeSuppressed := true

            if IsObject(ActiveMcpConfig)
            && !ActiveMcpConfig.External {
                ActiveMcpConfig := 0
                ActiveMcpDirectories := ""
            }
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
        McpProbeSuppressed := true
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


    ; --------------------------------------------------------
    ;  KNOWN OFFLINE — NO AUTOMATIC HTTP PROBE
    ; --------------------------------------------------------

    if McpProbeSuppressed
    && !Owned
    && !InStartupGrace {
        McpStartupUntil := 0
        McpState := "offline"
        ActiveMcpStatus.Text := "○ Offline"
        ActiveMcpName.Text :=
			GetMcpClientURL(
				Desired
			)
        ActiveMcpDetails.Text := DisplayDirectories(
            Desired.Directories
        )

        ActiveMcpEditButton.Enabled := true
        ActiveMcpStartButton.Enabled := Desired.Enabled
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

    if Status != 0 {
        McpStartupUntil := 0
        McpProbeSuppressed := false
    }


    ; --------------------------------------------------------
    ;  STARTUP GRACE
    ; --------------------------------------------------------

    if Status = 0
    && A_TickCount < McpStartupUntil {
        McpState := "loading"
        McpProbeSuppressed := false
        ActiveMcpStatus.Text := "◐ Loading"
        ActiveMcpName.Text :=
			GetMcpClientURL(
				Runtime
			)

        ActiveMcpEditButton.Enabled := false
        ActiveMcpStartButton.Enabled := false
        ActiveMcpRestartButton.Enabled := false
        ActiveMcpStopButton.Enabled := Owned

        return false
    }


    ; --------------------------------------------------------
    ;  OFFLINE
    ; --------------------------------------------------------

    if Status = 0 {
        McpStartupUntil := 0

        ; If an external/runtime snapshot has disappeared, release it.
        ; The next pass should reflect whatever is currently saved.
        if IsObject(ActiveMcpConfig)
        && !Owned {
            ActiveMcpConfig := 0
            ActiveMcpDirectories := ""
            McpProbeSuppressed := true
            return UpdateMcpState()
        }

        if !Owned
            McpProbeSuppressed := true

        McpState := Owned
            ? "error"
            : "offline"

        ActiveMcpStatus.Text := Owned
            ? "! Offline"
            : "○ Offline"

        ActiveMcpName.Text :=
			GetMcpClientURL(
				Runtime
			)

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
    ActiveMcpName.Text :=
		GetMcpClientURL(
			Runtime
		)

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

EnterActiveView(
    ModelKey,
    Context,
    Cache,
    ServerKey := "",
    ModelMcpDirectories := ""
) {
    global ControllerMode
    global ActiveHasLaunched

    global ActiveModelKey
    global ActiveServerKey
    global ActiveServerConfig
    global ActiveContext
    global ActiveCache
    global ActiveModelMcpDirectories
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
    global LlamaProbeSuppressed
    global McpProbeSuppressed
    global LlamaStartupUntil, LlamaStartupGrace
    global McpStartupUntil, McpStartupGrace

    ActiveModelKey := ModelKey
    ActiveServerKey := ServerKey != "" ? ServerKey : Models[ModelKey].ServerKey
    ActiveServerConfig := CreateServerRuntimeConfig(ActiveServerKey)
    ActiveContext := Context
    ActiveCache := Cache
    ActiveModelMcpDirectories := ModelMcpDirectories

    ActiveMcpConfig := 0
    ActiveMcpDirectories := ""

    ActiveLlamaEditButton.Enabled := false

    ControllerMode := "active"
    ActiveHasLaunched := false

    LlamaStartupUntil :=
        A_TickCount
        + LlamaStartupGrace

    LlamaProbeSuppressed := false
    McpProbeSuppressed := false
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

    ActiveLlamaDetails.Text := GetActiveLlamaDetails()

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
		ActiveMcpName.Text :=
			GetMcpClientURL(
				DesiredMcp
			)
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

ForceControlPaint(Control) {
    DllCall(
        "user32\UpdateWindow",
        "ptr", Control.Hwnd
    )
}


; ============================================================
;  ACTIVE LLAMA CONTROLS
; ============================================================

StartActiveLlama(*) {
    global ActiveModelKey
    global ActiveServerKey
    global ActiveServerConfig
    global ActiveContext
    global ActiveCache

    global ActiveLlamaStatus
    global ActiveLlamaStartButton
    global ActiveLlamaRestartButton
    global ActiveLlamaStopButton

    global FastPollRate
    global LlamaProbeSuppressed
    global LlamaStartupUntil, LlamaStartupGrace
    global LlamaState


    SetActivePollRate(
        FastPollRate
    )

    ; Every deliberate start receives a fresh grace window before any probe
    ; or validation can yield to the Active polling timer.
    LlamaStartupUntil :=
        A_TickCount
        + LlamaStartupGrace

    LlamaProbeSuppressed := false
    LlamaState := "loading"

    ActiveLlamaStatus.Text :=
        "◐ Starting"

    ActiveLlamaStartButton.Enabled := false
    ActiveLlamaRestartButton.Enabled := false
    ActiveLlamaStopButton.Enabled := false
    ForceControlPaint(ActiveLlamaStatus)

    DesiredServer := CreateServerRuntimeConfig(
        ActiveServerKey
    )

    if !DesiredServer {
        ActiveServerConfig := 0

        MsgBox(
            "The active model references an unregistered llama server:`n`n"
            . ActiveServerKey,
            "Local AI",
            "Icon!"
        )

        LlamaStartupUntil := 0
        LlamaProbeSuppressed := true
        UpdateActiveState()
        return
    }

    HealthURL := GetServerHealthURL(
        DesiredServer
    )

    if HealthURL != ""
    && HttpStatus(HealthURL, 200) != 0 {
        LlamaStartupUntil := 0
        ActiveServerConfig := DesiredServer
        UpdateActiveState()
        return
    }

    if StartLlama(
        ActiveModelKey,
        ActiveContext,
        ActiveCache,
        ActiveServerKey
    ) {
        ActiveServerConfig := DesiredServer
        RefreshActiveLlamaDetails()
    }
    else {
        LlamaStartupUntil := 0
        LlamaProbeSuppressed := true
        UpdateActiveState()
    }
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
    global ActiveServerConfig

    RestartLlamaWithOfflineURL(
        GetServerHealthURL(
            ActiveServerConfig
        )
    )
}


StopActiveLlama(*) {
    global LlamaPid
    global ActiveServerConfig

    global ActiveLlamaStatus
    global FastPollRate
    global LlamaProbeSuppressed


    SetActivePollRate(
        FastPollRate
    )

    Server := ActiveServerConfig


    ; --------------------------------------------------------
    ;  OWNED
    ; --------------------------------------------------------

    if LlamaPid
    && ProcessExist(LlamaPid) {
        HealthURL := GetServerHealthURL(
            Server
        )

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

        LlamaProbeSuppressed := true
        UpdateActiveState()
        return
    }


    ; --------------------------------------------------------
    ;  EXTERNAL
    ; --------------------------------------------------------

    if !IsObject(Server) {
        MsgBox(
            "No active llama-server endpoint is available.",
            "Local AI",
            "Icon!"
        )

        return
    }

    HealthURL := GetServerHealthURL(
        Server
    )

    if HealthURL = ""
    || HttpStatus(HealthURL) = 0
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

    LlamaProbeSuppressed := true
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
    global ActiveMcpStartButton
    global ActiveMcpRestartButton
    global ActiveMcpStopButton
    global McpStartupUntil, McpStartupGrace
    global McpProbeSuppressed
    global McpState
    global FastPollRate

    SetActivePollRate(FastPollRate)

    ; As with llama, establish startup intent before the first probe so the
    ; polling timer can never collapse a deliberate start back to Offline.
    McpStartupUntil :=
        A_TickCount
        + McpStartupGrace

    McpProbeSuppressed := false
    McpState := "loading"

    Desired := GetSavedMcpConfig(
        ActiveModelKey
    )

    if !Desired.Enabled {
        McpStartupUntil := 0
        ActiveMcpConfig := 0
        ActiveMcpDirectories := ""
        McpProbeSuppressed := true
        UpdateActiveState()
        return
    }

    ActiveMcpStatus.Text := "◐ Starting"
    ActiveMcpStartButton.Enabled := false
    ActiveMcpRestartButton.Enabled := false
    ActiveMcpStopButton.Enabled := false
    ForceControlPaint(ActiveMcpStatus)

    if HttpStatus(
        GetMcpStatusURL(
            Desired
        )
    ) != 0 {
        McpStartupUntil := 0
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
        McpProbeSuppressed := true
        UpdateActiveState()
        return
    }

    McpStartupUntil :=
        A_TickCount
        + McpStartupGrace

    try StartMcp(
        Desired
    )
    catch Error as Err {
        McpStartupUntil := 0
        ActiveMcpConfig := 0
        ActiveMcpDirectories := ""
        McpProbeSuppressed := true

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
    global McpProbeSuppressed
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
        McpProbeSuppressed := true
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
    McpProbeSuppressed := true
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

    UpdateMainModelInfo()

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
    global ControllerMode
    global ActiveModelKey
    global ActiveModelMcpDirectories

    ModelDirectories := ""

    if ControllerMode = "active"
    && ModelKey != ""
    && ModelKey = ActiveModelKey {
        ModelDirectories := ActiveModelMcpDirectories
    }
    else if ModelKey != ""
    && Models.Has(ModelKey) {
        ModelDirectories := Models[ModelKey].McpDirectories
    }

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
    global McpEnabled, McpProxyExecutable, McpAddress, McpPort

    return {
        Enabled: McpEnabled,
        ProxyExecutable: Trim(McpProxyExecutable),
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
        ProxyExecutable: Config.HasOwnProp("ProxyExecutable")
            ? Trim(Config.ProxyExecutable)
            : "",
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

    AProxy := A.HasOwnProp("ProxyExecutable") ? Trim(A.ProxyExecutable) : ""
    BProxy := B.HasOwnProp("ProxyExecutable") ? Trim(B.ProxyExecutable) : ""

    if StrLower(AProxy) != StrLower(BProxy)
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

GetMcpClientURL(Config) {
    return GetMcpBaseURL(
        Config
    )
        . "/sse"
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



BrowseMcpDirectory(EditControl) {
    Existing := DirectoriesFromEdit(
        EditControl.Text
    )

    StartDirectory := ""

    for Directory in StrSplit(Existing, "|") {
        Directory := Trim(Directory)

        if Directory != ""
        && DirExist(Directory) {
            ; The * keeps this directory selected initially while allowing
            ; navigation upward through its parents and the wider tree.
            StartDirectory := "*" Directory
            break
        }
    }

    SelectedDirectory := DirSelect(
        StartDirectory,
        0,
        "Select MCP directory"
    )

    if SelectedDirectory = ""
        return

    EditControl.Text := DirectoriesForEdit(
        MergeMcpDirectories(
            Existing,
            SelectedDirectory
        )
    )
}


DiscoverMcpProxyExecutable() {
    ; Prefer whatever the user/install manager has exposed on PATH.
    Path := FindExecutableOnPath("mcp-proxy.exe")
    if Path != ""
        return Path

    ; uv and pipx allow their executable directories to be overridden.
    for VariableName in ["UV_TOOL_BIN_DIR", "PIPX_BIN_DIR"] {
        BinDirectory := Trim(EnvGet(VariableName))

        if BinDirectory = ""
            continue

        Candidate := RTrim(BinDirectory, "\/") "\mcp-proxy.exe"
        if FileExist(Candidate)
            return Candidate
    }

    ; Both uv tool and modern pipx commonly expose user tools here.
    UserProfile := Trim(EnvGet("USERPROFILE"))
    if UserProfile != "" {
        Candidate := UserProfile "\.local\bin\mcp-proxy.exe"
        if FileExist(Candidate)
            return Candidate
    }

    ; pip --user installs commonly create PythonXY\Scripts beneath Roaming AppData.
    PythonRoot := A_AppData "\Python"
    if DirExist(PythonRoot) {
        Loop Files PythonRoot "\Python*", "D" {
            Candidate := A_LoopFileFullPath "\Scripts\mcp-proxy.exe"

            if FileExist(Candidate)
                return Candidate
        }
    }

    return ""
}


FindExecutableOnPath(FileName) {
    try {
        Shell := ComObject(
            "WScript.Shell"
        )

        Exec := Shell.Exec(
            'where.exe "' FileName '"'
        )

        Output := Exec.StdOut.ReadAll()

        for Line in StrSplit(Output, "`n") {
            Candidate := Trim(Line)

            if Candidate != ""
            && FileExist(Candidate)
                return Candidate
        }
    }

    return ""
}

BrowseMcpProxyExecutable(EditControl) {
    StartPath := Trim(EditControl.Text)

    if StartPath = ""
        StartPath := DiscoverMcpProxyExecutable()

    SelectedPath := FileSelect(
        1,
        StartPath,
        "Select mcp-proxy executable",
        "mcp-proxy executable (mcp-proxy.exe)"
    )

    if SelectedPath != ""
        EditControl.Text := SelectedPath
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
    global KvCacheOptions

    Cache := StrLower(
        Trim(Cache)
    )

    for Index, Option in KvCacheOptions {
        if Option = Cache {
            Control.Choose(Index)
            return
        }
    }

    ; q4_0 remains WinLlama's safe model default.
    for Index, Option in KvCacheOptions {
        if Option = "q4_0" {
            Control.Choose(Index)
            return
        }
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

OpenServerManager(
    ParentGui,
    SelectedServerKey := "",
    OnChanged := 0,
    SetupMode := false,
    OnContinue := 0
) {
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

    ManagerGui := Gui(
        ,
        SetupMode
            ? "WinLlama Setup - Llama Servers"
            : "Llama Servers"
    )

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

    ContinueButton := 0

    if SetupMode {
        ManagerGui.SetFont("s12 c" TextColor, "Segoe UI")
        ContinueButton := ManagerGui.AddButton("x24 y211 w480 h42", "Continue")
        MakeOwnerDrawButton(ContinueButton)
    }

    ServerManagerState := {
        Gui: ManagerGui,
        Parent: ParentGui,
        ServerControl: ServerControl,
        ServerKeys: [],
        SummaryText: SummaryText,
        EditButton: EditButton,
        DeleteButton: DeleteButton,
        ContinueButton: ContinueButton,
        SetupMode: SetupMode,
        OnChanged: OnChanged,
        OnContinue: OnContinue
    }

    ServerControl.OnEvent("Change", UpdateServerManagerDetails)
    EditButton.OnEvent("Click", EditSelectedServer)
    AddButton.OnEvent("Click", (*) => OpenServerEditor(ManagerGui))
    DeleteButton.OnEvent("Click", DeleteSelectedServer)

    if SetupMode
        ContinueButton.OnEvent("Click", ContinueServerSetup)

    ManagerGui.OnEvent("Close", CloseServerManager)

    RefreshServerManager(SelectedServerKey)
    ShowRelative(ManagerGui, ParentGui)
}


CloseServerManager(*) {
    global ServerManagerState

    if !IsObject(ServerManagerState)
        return

    if ServerManagerState.SetupMode {
        ExitApp()
        return
    }

    DismissServerManager()
}


DismissServerManager(ShowParent := true) {
    global ServerManagerState

    if !IsObject(ServerManagerState)
        return

    State := ServerManagerState
    try State.Gui.Destroy()
    ServerManagerState := 0

    State.Parent.Opt("-Disabled")

    if ShowParent {
        State.Parent.Show()
        try WinActivate("ahk_id " State.Parent.Hwnd)
    }
}


ContinueServerSetup(*) {
    global ServerManagerState

    if !IsObject(ServerManagerState)
        return

    ServerKey := GetSelectedServerManagerKey()

    if !IsStructurallyValidServer(ServerKey) {
        MsgBox(
            "Select or register a llama server before continuing.",
            "WinLlama Setup",
            "Icon!"
        )
        return
    }

    Callback := ServerManagerState.OnContinue

    DismissServerManager(false)

    if IsObject(Callback)
        Callback.Call(ServerKey)
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

        if IsObject(State.ContinueButton)
            State.ContinueButton.Enabled := false

        return
    }

    Server := Servers[ServerKey]
    State.SummaryText.Text := Server.Address ":" Server.Port "`n" Server.Executable
    State.EditButton.Enabled := true
    State.DeleteButton.Enabled := true

    if IsObject(State.ContinueButton)
        State.ContinueButton.Enabled := IsStructurallyValidServer(ServerKey)
}


EditSelectedServer(*) {
    global ServerManagerState

    ServerKey := GetSelectedServerManagerKey()
    if ServerKey != ""
        OpenServerEditor(ServerManagerState.Gui, ServerKey)
}


DeleteSelectedServer(*) {
    ServerKey := GetSelectedServerManagerKey()
    if ServerKey = ""
        return

    if !ConfirmDeleteServer(ServerKey)
        return

    RefreshServerManager()
}


ConfirmDeleteServer(ServerKey) {
    global Servers

    if ServerKey = "" || !Servers.Has(ServerKey)
        return false

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
        return false

    DeleteServer(ServerKey)
    NotifyServerManagerChanged()
    return true
}


OpenServerEditor(ParentGui, ServerKey := "", OnSaved := 0) {
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
        : {Name: "", Executable: "", Address: "127.0.0.1", Port: 9931, Args: ""}

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
    NameEdit := EditorGui.AddEdit("x24 y99 w480 r1 -Multi Background" SecondaryColor " c" TextColor, Server.Name)

    EditorGui.AddText("x24 y145", "Executable")
    ExecutableEdit := EditorGui.AddEdit(
        "x24 y174 w438 r1 -Multi Background" SecondaryColor " c" TextColor, Server.Executable
    )

    EditorGui.SetFont("s11 c" TextColor, "Segoe UI")
    BrowseButton := EditorGui.AddButton("x470 y173 w34 h26", "…")
    MakeOwnerDrawButton(BrowseButton)

    EditorGui.SetFont("s12 Norm c" TextColor, "Segoe UI")
    EditorGui.AddText("x24 y220", "Address")
    EditorGui.AddText("x374 y220", "Port")
    AddressEdit := EditorGui.AddEdit(
        "x24 y249 w330 r1 -Multi Background" SecondaryColor " c" TextColor, Server.Address
    )
    PortEdit := EditorGui.AddEdit(
        "x374 y249 w130 r1 -Multi Number Background" SecondaryColor " c" TextColor, Server.Port
    )

    EditorGui.AddText("x24 y295", "Optional arguments")
    ArgsEdit := EditorGui.AddEdit("x24 y324 w480 r1 -Multi Background" SecondaryColor " c" TextColor, Server.Args)

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
        Gui: EditorGui, Parent: ParentGui, ServerKey: ServerKey, OnSaved: OnSaved, NameEdit: NameEdit,
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
        1,
        Trim(ExecutableEdit.Text),
        "Select llama-server executable",
        "llama-server executable (llama-server.exe)"
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

    Callback := State.OnSaved

    CloseServerEditor()
    RefreshServerManager(SavedKey)
    NotifyServerManagerChanged(SavedKey)

    if IsObject(Callback)
        Callback.Call(SavedKey)
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
    global MainGui, ActiveGui

    if IsObject(ServerManagerState) {
        Callback := ServerManagerState.OnChanged
        if IsObject(Callback)
            Callback.Call(ServerKey)
    }

    ; Setup can use the same registry UI before Start/Active windows exist.
    ; When those views do exist, refresh them without rewriting live runtime
    ; endpoint snapshots.
    if IsSet(MainGui) && IsObject(MainGui)
        UpdateMainModelInfo()

    if IsSet(ActiveGui) && IsObject(ActiveGui)
        RefreshActiveLlamaDetails()
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
                9931,
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
    Port := 9931,
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

CreateServerRuntimeConfig(ServerKey) {
    Server := GetServer(
        ServerKey
    )

    if !Server
        return 0

    return {
        Key: ServerKey,
        Name: Server.Name,
        Executable: Server.Executable,
        Address: Server.Address,
        Port: Server.Port,
        Args: Server.Args
    }
}


SameServerRuntimeConfig(A, B) {
    if !IsObject(A)
    || !IsObject(B)
        return false

    return StrLower(Trim(A.Executable)) = StrLower(Trim(B.Executable))
        && StrLower(Trim(A.Address)) = StrLower(Trim(B.Address))
        && (A.Port + 0) = (B.Port + 0)
        && Trim(A.Args) = Trim(B.Args)
}


GetServerWebUI(Server) {
    if !IsObject(Server)
        return ""

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


GetServerHealthURL(Server) {
    WebUI := GetServerWebUI(
        Server
    )

    return WebUI != ""
        ? WebUI . "/health"
        : ""
}


GetActiveServerDisplayName() {
    global ActiveServerKey
    global ActiveServerConfig

    if IsObject(ActiveServerConfig) {
        if ActiveServerConfig.Key = ActiveServerKey {
            Registered := GetServer(
                ActiveServerKey
            )

            if Registered
                return Registered.Name
        }

        return ActiveServerConfig.Name
    }

    Registered := GetServer(
        ActiveServerKey
    )

    return Registered
        ? Registered.Name
        : ActiveServerKey
}


GetActiveServerPendingNote() {
    global ActiveServerKey
    global ActiveServerConfig

    if !IsObject(ActiveServerConfig)
        return ""

    if ActiveServerConfig.Key != ActiveServerKey
        return "Server changes pending"

    Registered := GetServer(
        ActiveServerKey
    )

    if !Registered
        return "Server registration removed"

    return SameServerRuntimeConfig(
        ActiveServerConfig,
        Registered
    )
        ? ""
        : "Server changes pending"
}


GetActiveLlamaDetails() {
    global ActiveContext
    global ActiveCache
    global ActiveServerKey
    global ActiveServerConfig

    if !IsObject(ActiveServerConfig)
        return "Server not registered: " ActiveServerKey

    Details :=
        ActiveContext
        . " context  •  "
        . ActiveCache
        . " KV  •  "
        . GetActiveServerDisplayName()
        . "  •  Port "
        . ActiveServerConfig.Port

    Note := GetActiveServerPendingNote()

    if Note != ""
        Details .= "  •  " Note

    return Details
}


RefreshActiveLlamaDetails() {
    global ControllerMode
    global ActiveLlamaDetails

    if ControllerMode != "active"
        return

    ActiveLlamaDetails.Text := GetActiveLlamaDetails()
}

; ============================================================
;  APPLICATION FUNCTIONS
; ============================================================

AcquireInstanceMutex() {
    Mutex := DllCall(
        "Kernel32\CreateMutexW",
        "ptr", 0,
        "int", false,
        "str", "Local\WinLlama_Controller_Instance",
        "ptr"
    )

    if !Mutex {
        MsgBox(
            "WinLlama could not create its instance guard.",
            "Local AI",
            "Iconx"
        )

        return 0
    }

    if DllCall(
        "Kernel32\GetLastError",
        "uint"
    ) = 183 {
        Result := MsgBox(
            "Another WinLlama controller is already running.`n`n"
            . "Open a second instance anyway?",
            "WinLlama Already Running",
            "YesNo Icon?"
        )

        if Result != "Yes" {
            DllCall(
                "Kernel32\CloseHandle",
                "ptr", Mutex
            )

            return 0
        }
    }

    return Mutex
}


CleanupOwnedServices(ExitReason, ExitCode) {
    global LlamaPid, McpPid
    global InstanceMutex

    SaveCurrentControllerWindowCenter()

    if LlamaPid && ProcessExist(LlamaPid)
        StopProcessTree(LlamaPid)

    if McpPid && ProcessExist(McpPid)
        StopProcessTree(McpPid)

    FinalizeAllCapturedProcesses()

    if InstanceMutex {
        DllCall(
            "Kernel32\CloseHandle",
            "ptr", InstanceMutex
        )

        InstanceMutex := 0
    }
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

ShowStartupWindow() {
    global MainGui
    global SavedWindowCenterX, SavedWindowCenterY

    if SavedWindowCenterX = ""
    || SavedWindowCenterY = "" {
        MainGui.Show("w572")
        return
    }

    MainGui.Show("Hide w572")

    Rect := Buffer(16)

    DllCall(
        "user32\GetWindowRect",
        "ptr", MainGui.Hwnd,
        "ptr", Rect
    )

    Width :=
        NumGet(Rect, 8, "Int")
        - NumGet(Rect, 0, "Int")

    Height :=
        NumGet(Rect, 12, "Int")
        - NumGet(Rect, 4, "Int")

    X := Round(SavedWindowCenterX - Width / 2)
    Y := Round(SavedWindowCenterY - Height / 2)

    ClampToDesktop(
        &X,
        &Y,
        Width,
        Height
    )

    DllCall(
        "user32\SetWindowPos",
        "ptr", MainGui.Hwnd,
        "ptr", 0,
        "int", X,
        "int", Y,
        "int", 0,
        "int", 0,
        "uint", 0x0001 | 0x0004
    )

    MainGui.Show()
}


SaveCurrentControllerWindowCenter() {
    global ControllerMode
    global MainGui, ActiveGui

    if ControllerMode = "active"
    && IsSet(ActiveGui)
    && IsObject(ActiveGui) {
        SaveControllerWindowCenter(ActiveGui)
        return
    }

    if ControllerMode = "start"
    && IsSet(MainGui)
    && IsObject(MainGui)
        SaveControllerWindowCenter(MainGui)
}


SaveControllerWindowCenter(GuiObj) {
    global SavedWindowCenterX, SavedWindowCenterY

    if !IsObject(GuiObj)
        return

    try {
        Rect := Buffer(16)

        DllCall(
            "user32\GetWindowRect",
            "ptr", GuiObj.Hwnd,
            "ptr", Rect
        )

        Left := NumGet(Rect, 0, "Int")
        Top := NumGet(Rect, 4, "Int")
        Right := NumGet(Rect, 8, "Int")
        Bottom := NumGet(Rect, 12, "Int")

        SavedWindowCenterX := Round((Left + Right) / 2)
        SavedWindowCenterY := Round((Top + Bottom) / 2)

        ConfigWriteMany(
            "State",
            Map(
                "WindowCenterX", SavedWindowCenterX,
                "WindowCenterY", SavedWindowCenterY
            )
        )
    }
}

HideController(GuiObj, *) {
    SaveControllerWindowCenter(GuiObj)
    GuiObj.Hide()
}


ShowController(*) {
    global ControllerMode
    global MainGui, ActiveGui
    global ActiveConfigDialog
    global ServerManagerState

    if ControllerMode = "setup" {
        if IsObject(ActiveConfigDialog) {
            RaiseConfigDialog()
            return
        }

        if IsObject(ServerManagerState) {
            try {
                ServerManagerState.Gui.Show()
                WinActivate("ahk_id " ServerManagerState.Gui.Hwnd)
            }
            return
        }

        return
    }

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
    global ActiveServerConfig

    WebUI := GetServerWebUI(
        ActiveServerConfig
    )

    if WebUI = "" {
        MsgBox(
            "No active llama-server endpoint is available.",
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

        ; Make sure :PORT doesn't accidentally match a longer port number.
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

