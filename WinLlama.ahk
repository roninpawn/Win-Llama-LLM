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

McpPort := ConfigReadInteger(
    "MCP",
    "Port",
    18081
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
ActiveContext := 0
ActiveCache := ""
ActiveMcpDirectories := ""

ActiveConfigDialog := 0

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

SaveModelDefaults(
    ModelKey,
    Context,
    Cache
) {
    global Models

    ConfigWriteMany(
        ModelKey,
        Map(
            "Context", Context,
            "Cache", Cache
        )
    )

    Models[ModelKey].Context := Context
    Models[ModelKey].Cache := Cache
}


SaveMcpDefaults(Directories) {
    global McpDirectories

    ConfigWrite(
        "MCP",
        "GlobalDirectories",
        Directories
    )

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
    __New(GuiObj, X, Y, Width, ModelKey, Context := "", Cache := "") {
        global Models, ModelList
        global SecondaryColor, TextColor, MutedColor

        this.Gui := GuiObj
        this.X := X
        this.Y := Y
        this.Width := Width

        GuiObj.SetFont(
            "s12 Norm c" TextColor,
            "Segoe UI"
        )

        GuiObj.AddText(
            "x" X " y" Y,
            "Model"
        )

        ModelNames := []

        for Key in ModelList
            ModelNames.Push(Models[Key].Name)

        Y += 29

        this.ModelControl := GuiObj.AddDropDownList(
            "x" X " y" Y " w" Width " +0x210",
            ModelNames
        )

        ApplyDarkControl(this.ModelControl)

        Y += 50

        GuiObj.AddText(
            "x" X " y" Y,
            "Context"
        )

        Y += 29

        this.ContextControl := GuiObj.AddComboBox(
            "x" X " y" Y " w" Width
            . " +0x210 Background"
            . SecondaryColor
            . " c"
            . TextColor,
            [
                "16384",
                "24576",
                "32768"
            ]
        )

        ApplyDarkControl(this.ContextControl)

        Y += 50

        GuiObj.AddText(
            "x" X " y" Y,
            "KV cache"
        )

        Y += 29

        this.CacheControl := GuiObj.AddDropDownList(
            "x" X " y" Y " w" Width " +0x210",
            [
                "f16",
                "q8_0",
                "q4_0"
            ]
        )

        ApplyDarkControl(this.CacheControl)

        Y += 45

        GuiObj.SetFont(
            "s10 c" MutedColor,
            "Segoe UI"
        )

        this.DefaultsText := GuiObj.AddText(
            "x" X " y" Y " w" Width,
            ""
        )

        this.Bottom := Y + 24

        this.ModelControl.OnEvent(
            "Change",
            ObjBindMethod(
                this,
                "ResetToModelDefaults"
            )
        )

        this.SetValues(
            ModelKey,
            Context,
            Cache
        )
    }


    SetValues(ModelKey, Context := "", Cache := "") {
        global Models, ModelList

        for Index, Key in ModelList {
            if Key = ModelKey {
                this.ModelControl.Choose(Index)
                break
            }
        }

        Model := Models[ModelKey]

        this.ContextControl.Text :=
            Context != ""
            ? Context
            : Model.Context

        ChooseCache(
            this.CacheControl,
            Cache != ""
            ? Cache
            : Model.Cache
        )

        this.UpdateDefaultsText()
    }


    ResetToModelDefaults(*) {
        global Models

        Key := this.GetModelKey()
        Model := Models[Key]

        this.ContextControl.Text := Model.Context

        ChooseCache(
            this.CacheControl,
            Model.Cache
        )

        this.UpdateDefaultsText()
    }


    UpdateDefaultsText() {
        global Models

        Key := this.GetModelKey()
        Model := Models[Key]

        this.DefaultsText.Text :=
            "Configured defaults:  "
            . Model.Context
            . " context  /  "
            . Model.Cache
            . " KV"
    }


    GetModelKey() {
        global ModelList

        return ModelList[
            this.ModelControl.Value
        ]
    }


    GetValues() {
        Context := Trim(
            this.ContextControl.Text
        )

        if !IsInteger(Context) || Context <= 0 {
            MsgBox(
                "Context must be a positive integer.",
                "Local AI",
                "Icon!"
            )

            return false
        }

        return {
            ModelKey: this.GetModelKey(),
            Context: Context + 0,
            Cache: this.CacheControl.Text
        }
    }
}


class McpConfigPanel {
    __New(GuiObj, X, Y, Width, Directories) {
        global SecondaryColor, TextColor, MutedColor

        this.Gui := GuiObj
        this.X := X
        this.Y := Y
        this.Width := Width

        GuiObj.SetFont(
            "s12 Norm c" TextColor,
            "Segoe UI"
        )

        GuiObj.AddText(
            "x" X " y" Y,
            "MCP directories"
        )

        Y += 27

        GuiObj.SetFont(
            "s10 c" MutedColor,
            "Segoe UI"
        )

        GuiObj.AddText(
            "x" X " y" Y " w" Width,
            "One explicitly allowed directory per line"
        )

        Y += 27

        GuiObj.SetFont(
            "s11 c" TextColor,
            "Segoe UI"
        )

        this.DirectoryEdit := GuiObj.AddEdit(
            "x" X " y" Y
            . " w" Width
            . " r4 -VScroll Background"
            . SecondaryColor
            . " c"
            . TextColor,
            DirectoriesForEdit(
                Directories
            )
        )

        this.Bottom := Y + 94
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

    Directories :=
        McpPanel.GetDirectories()

    if Directories = "" {
        MsgBox(
            "At least one MCP directory must be specified.",
            "Local AI",
            "Icon!"
        )

        return
    }

    if !VerifyDirectories(Directories)
        return

    ConfigGui.Destroy()

    EnterActiveView(
        Values.ModelKey,
        Values.Context,
        Values.Cache,
        Directories
    )

    LaunchAI(
        Values.ModelKey,
        Values.Context,
        Values.Cache,
        Directories
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
        ActiveCache
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
			ActiveModelKey
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
        Values.Context,
        Values.Cache
    )

    ModelPanel.UpdateDefaultsText()
    UpdateMainModelInfo()
}

SyncMainModelSelection(ModelKey) {
    global MainModelControl
    global ModelList

    for Index, Key in ModelList {
        if Key = ModelKey {
            MainModelControl.Choose(Index)
            break
        }
    }

    UpdateMainModelInfo()
}

; ============================================================
;  MCP ACCESS EDITOR
; ============================================================

OpenMcpEditor(*) {
    global ActiveMcpDirectories
    global BaseColor, TextColor

    EditorGui := Gui(
        ,
        "MCP Access"
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
        "MCP ACCESS"
    )


    McpPanel := McpConfigPanel(
        EditorGui,
        24,
        70,
        480,
        ActiveMcpDirectories
    )


    EditorGui.SetFont(
        "s12 c" TextColor,
        "Segoe UI"
    )

	ApplyButton := EditorGui.AddButton(
		"x24 y" McpPanel.Bottom + 22
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

	SaveDefaultsButton.OnEvent(
		"Click",
		(*) => SaveMcpEditorDefaults(
			McpPanel
		)
	)

    ApplyButton.OnEvent(
        "Click",
        (*) => ApplyMcpAccess(
            EditorGui,
            McpPanel
        )
    )

    CancelButton.OnEvent(
        "Click",
        (*) => EndConfigDialog(EditorGui, ActiveGui)
    )

    ShowRelative(
		EditorGui,
		ActiveGui
	)
}

SaveMcpEditorDefaults(McpPanel) {
    global MainMcpText
    global McpDirectories

    Directories :=
        GetValidMcpDirectories(
            McpPanel
        )

    if !Directories
        return

    SaveMcpDefaults(
        Directories
    )

    MainMcpText.Text :=
        DisplayDirectories(
            McpDirectories
        )
}

ApplyMcpAccess(EditorGui, McpPanel) {
    global ActiveMcpDirectories
    global McpPid, McpPort

	Directories :=
		GetValidMcpDirectories(
			McpPanel
		)

	if !Directories
		return

    if !VerifyDirectories(Directories)
        return

	if SameDirectories(
		Directories,
		ActiveMcpDirectories
	) {
		EndConfigDialog(
			EditorGui,
			ActiveGui
		)
		return
	}

    Status := HttpStatus(
        "http://127.0.0.1:"
        . McpPort
        . "/status"
    )

    Owned :=
        McpPid
        && ProcessExist(McpPid)


    ; Do not commandeer somebody else's MCP process.

    if Status != 0 && !Owned {
        MsgBox(
            "The active MCP service was not started by this controller.`n`n"
            . "Its access configuration cannot be changed safely.",
            "MCP Access",
            "Icon!"
        )

        return
    }


    ActiveMcpDirectories := Directories

    EndConfigDialog(
		EditorGui,
		ActiveGui
	)


    ; If MCP is running, applying new access means restart.
    ; If it is offline, simply stage the new directories.

    if Status != 0
        RestartActiveMcp()
    else
        UpdateActiveState()
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
        'm)^INFO:\s+127\.0\.0\.1:\d+\s+-\s+"GET /status HTTP/1\.1"\s+200 OK\r?\n?'
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

LaunchAI(ModelKey, ContextOverride, CacheOverride, Directories) {
	global Models
	global McpPort
    global ActiveHasLaunched

    Model := Models[ModelKey]
	
	Server :=
		GetModelServer(
			ModelKey
		)

	if !Server {
		MsgBox(
			"The model '" Model.Name "' references an unregistered llama server:`n`n"
			. Model.ServerKey,
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

    if !VerifyDirectories(Directories) {
        ReturnToStartup()
        return
    }


    ; --------------------------------------------------------
    ;  MCP
    ; --------------------------------------------------------

    McpURL :=
        "http://127.0.0.1:"
        . McpPort
        . "/status"

    if HttpStatus(McpURL) = 0 {
        StartMcp(Directories)

        if !WaitForHttp(
            McpURL,
            10000
        ) {
            MsgBox(
                "MCP was started, but did not become available.",
                "Local AI",
                "Icon!"
            )
        }
    }


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
			Cache
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

StartMcp(Directories) {
	global McpPort
    global McpPid
    global McpLog

    DirectoryArgs := ""

    for Directory in StrSplit(Directories, "|") {
        Directory := Trim(Directory)

        if Directory != ""
            DirectoryArgs .= ' "' Directory '"'
    }


	McpCommand :=
		"mcp-proxy "
		. "--host 127.0.0.1 "
		. "--port " McpPort " "
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

	Run(
		Command,
		A_ScriptDir,
		"Hide",
		&McpPid
	)

}

; ============================================================
;  START LLAMA
; ============================================================

StartLlama(
    ModelKey,
    Context,
    Cache
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

    Server :=
        GetModelServer(
            ModelKey
        )


    ; --------------------------------------------------------
    ;  VALIDATE SERVER
    ; --------------------------------------------------------

    if !Server {
	MsgBox(
		"The model '" Model.Name "' references an unregistered llama server:`n`n"
		. Model.ServerKey,
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

    Server :=
        GetModelServer(
            ActiveModelKey
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
            . Model.ServerKey

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
    global McpPid, McpPort
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


    if McpPid && !ProcessExist(McpPid)
        McpPid := 0

    Owned :=
        McpPid
        && ProcessExist(McpPid)

    Status := HttpStatus(
        "http://127.0.0.1:"
        . McpPort
        . "/status"
    )
	
	if Status != 0
		McpStartupUntil := 0


    ; --------------------------------------------------------
    ;  OFFLINE
    ; --------------------------------------------------------

    if Status = 0 {
		if A_TickCount < McpStartupUntil {
			McpState := "loading"
			ActiveMcpStatus.Text := "◐ Loading"

			ActiveMcpEditButton.Enabled := false
			ActiveMcpStartButton.Enabled := false
			ActiveMcpRestartButton.Enabled := false
			ActiveMcpStopButton.Enabled := true

			return false
		}

		McpStartupUntil := 0

        McpState := "offline"
		ActiveMcpStatus.Text := "○ Offline"
        ActiveMcpName.Text := "Filesystem"

        ActiveMcpDetails.Text :=
            DisplayDirectories(
                ActiveMcpDirectories
            )

        ActiveMcpEditButton.Enabled := true
        ActiveMcpStartButton.Enabled := true
        ActiveMcpRestartButton.Enabled := false
        ActiveMcpStopButton.Enabled := false

        return true
    }


    ; --------------------------------------------------------
    ;  EXTERNAL
    ; --------------------------------------------------------

    if !Owned {
        McpState := "external"
		ActiveMcpStatus.Text := "● External"
        ActiveMcpName.Text := "Existing MCP service"

        ActiveMcpDetails.Text :=
            "Port "
            . McpPort
            . "  •  Access configuration unknown"

        ActiveMcpEditButton.Enabled := false
        ActiveMcpStartButton.Enabled := false
        ActiveMcpRestartButton.Enabled := false
        ActiveMcpStopButton.Enabled := true

        return true
    }


    ; --------------------------------------------------------
    ;  OWNED
    ; --------------------------------------------------------

    McpState := "online"
	ActiveMcpStatus.Text := "● Online"
    ActiveMcpName.Text := "Filesystem"

    ActiveMcpDetails.Text :=
        DisplayDirectories(
            ActiveMcpDirectories
        )

    ActiveMcpEditButton.Enabled := true
    ActiveMcpStartButton.Enabled := false
    ActiveMcpRestartButton.Enabled := true
    ActiveMcpStopButton.Enabled := true
	
	return true
}

EnterActiveView(ModelKey, Context, Cache, Directories) {
    global ControllerMode
    global ActiveHasLaunched

    global ActiveModelKey
    global ActiveContext
    global ActiveCache
    global ActiveMcpDirectories

    global MainGui, ActiveGui
    global MainModelControl
    global ModelList, Models

    global ActiveLlamaStatus
    global ActiveLlamaName
    global ActiveLlamaDetails

    global ActiveMcpStatus
    global ActiveMcpName
    global ActiveMcpDetails

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
    ActiveContext := Context
    ActiveCache := Cache
    ActiveMcpDirectories := Directories
	
	ActiveLlamaEditButton.Enabled := false

	ControllerMode := "active"
	ActiveHasLaunched := false

	LlamaStartupUntil :=
		A_TickCount
		+ LlamaStartupGrace

	McpStartupUntil :=
		A_TickCount
		+ McpStartupGrace

	LlamaState := "loading"
	ActiveLlamaStatus.Text := "◐ Loading"
	McpState := "loading"
	ActiveMcpStatus.Text := "◐ Loading"


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

	ActiveLlamaStatus.Text := "◐ Starting"
    ActiveLlamaName.Text := Model.Name

    ActiveLlamaDetails.Text :=
        Context
        . " context  •  "
        . Cache
        . " KV"

    ActiveMcpStatus.Text := "◐ Starting"
    ActiveMcpName.Text := "Filesystem"

    ActiveMcpDetails.Text :=
        DisplayDirectories(Directories)


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
        ActiveCache
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
    global ActiveModelKey

    RestartLlamaWithOfflineURL(
        GetModelHealthURL(
            ActiveModelKey
        )
    )
}


StopActiveLlama(*) {
    global LlamaPid
    global ActiveModelKey

    global ActiveLlamaStatus
    global FastPollRate


    SetActivePollRate(
        FastPollRate
    )

    Server :=
        GetModelServer(
            ActiveModelKey
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
    global ActiveMcpDirectories
    global ActiveMcpStatus
    global McpStartupUntil, McpStartupGrace
    global FastPollRate

	SetActivePollRate(FastPollRate)
    
	McpStartupUntil :=
        A_TickCount
        + McpStartupGrace

    if !VerifyDirectories(
        ActiveMcpDirectories
    )
        return

    ActiveMcpStatus.Text := "◐ Starting"

    StartMcp(
        ActiveMcpDirectories
    )
}


RestartActiveMcp(*) {
    global McpPid, McpPort
    global ActiveMcpStatus
	global FastPollRate

	SetActivePollRate(FastPollRate)

    if !McpPid
        return

    ActiveMcpStatus.Text := "◐ Restarting"

    StopProcessTree(McpPid)
    McpPid := 0

    WaitForOffline(
        "http://127.0.0.1:"
        . McpPort
        . "/status",
        10000
    )

    StartActiveMcp()
}


StopActiveMcp(*) {
    global McpPid, McpPort
    global ActiveMcpStatus, FastPollRate

    SetActivePollRate(FastPollRate)

    StatusURL :=
        "http://127.0.0.1:"
        . McpPort
        . "/status"

    if HttpStatus(StatusURL) = 0
        return


    ; --------------------------------------------------------
    ;  OWNED
    ; --------------------------------------------------------

    if McpPid && ProcessExist(McpPid) {
        ActiveMcpStatus.Text := "◐ Stopping"

        StopProcessTree(McpPid)
        McpPid := 0
    }


    ; --------------------------------------------------------
    ;  EXTERNAL
    ; --------------------------------------------------------

    else {
        Result := MsgBox(
            "This MCP server was not started by the controller.`n`n"
            . "Terminate the process listening on port "
            . McpPort
            . "?",
            "Terminate External MCP",
            "YesNo Icon?"
        )

        if Result != "Yes"
            return

        ExternalPid := GetListeningPid(
            McpPort
        )

        if !ExternalPid {
            MsgBox(
                "The process using port "
                . McpPort
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

SameDirectories(A, B) {
    A := StrLower(Trim(A, " `t`r`n|"))
    B := StrLower(Trim(B, " `t`r`n|"))

    return A = B
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

GetValidMcpDirectories(McpPanel) {
    Directories :=
        McpPanel.GetDirectories()

    if Directories = "" {
        MsgBox(
            "At least one MCP directory must be specified.",
            "MCP Access",
            "Icon!"
        )

        return false
    }

    if !VerifyDirectories(Directories)
        return false

    return Directories
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


GetModelWebUI(ModelKey) {
    Server :=
        GetModelServer(
            ModelKey
        )

    if !Server
        return ""

    return GetServerWebUI(
        Server
    )
}


GetModelHealthURL(ModelKey) {
    WebUI :=
        GetModelWebUI(
            ModelKey
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
    global ActiveModelKey

    WebUI :=
        GetModelWebUI(
            ActiveModelKey
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

