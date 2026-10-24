; ============================================================================
;  runtime.pbi - Support console multi-plateforme (Windows / Linux / macOS)
;  Partage par tous les serveurs MCP du depot.
; ============================================================================
;  - Ecriture stderr : journalisation et diagnostics uniquement.
;  - Aucune lecture stdin : le transport est HTTP (voir http_server.pbi).
;  - Windows : kernel32 charge dynamiquement (GetStdHandle/WriteFile).
;  - Linux/macOS : write_() sur le descripteur 2.
; ============================================================================
;  A inclure en premier dans chaque serveur :
;    IncludeFile "../mcp_common/runtime.pbi"
; ============================================================================

CompilerIf #PB_Compiler_OS = #PB_OS_Windows
  #C_STD_ERROR_HANDLE  = -12

  ; Chargement dynamique de kernel32 : les noms ReadFile/WriteFile entrent
  ; en conflit avec des commandes PureBasic, on passe par PrototypeC.
  PrototypeC protoGetStdHandle(nStdHandle.i)
  PrototypeC protoWriteFile(hFile.i, *lpBuffer, nNumberOfBytesToWrite.l, *lpNumberOfBytesWritten, *lpOverlapped)

  Global hKernel32.i = OpenLibrary(#PB_Any, "kernel32.dll")
  Global Std_GetHandle.protoGetStdHandle = GetFunction(hKernel32, "GetStdHandle")
  Global Std_WriteFile.protoWriteFile    = GetFunction(hKernel32, "WriteFile")
CompilerEndIf

; ---------------------------------------------------------------------------
; Ecriture d'une ligne sur stderr (logs, diagnostics)
; ---------------------------------------------------------------------------
Procedure SendStderrLine(Text.s)
  Protected OutText.s = Text + #LF$
  Protected Size.i = StringByteLength(OutText, #PB_UTF8)
  If Size = 0 : ProcedureReturn : EndIf

  Protected *Mem = AllocateMemory(Size)
  If *Mem
    PokeS(*Mem, OutText, -1, #PB_UTF8 | #PB_String_NoZero)
    CompilerIf #PB_Compiler_OS = #PB_OS_Windows
      Protected hErr.i = Std_GetHandle(#C_STD_ERROR_HANDLE)
      Protected WrittenLow.l = 0
      Std_WriteFile(hErr, *Mem, Size, @WrittenLow, #Null)
    CompilerElse
      write_(2, *Mem, Size)
    CompilerEndIf
    FreeMemory(*Mem)
  EndIf
EndProcedure

; ---------------------------------------------------------------------------
; Verifier que la couche console est operationnelle
; ---------------------------------------------------------------------------
Procedure.i CheckRuntime()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If hKernel32 = 0 Or Std_GetHandle = 0 Or Std_WriteFile = 0
      ProcedureReturn #False
    EndIf
  CompilerEndIf
  ProcedureReturn #True
EndProcedure
