; ============================================================================
;  unit_test.pbi - Micro-framework de tests unitaires PureBasic
;  Sortie sur stderr (le serveur n'utilise pas stdout).
; ============================================================================
;  Usage dans un tests/test_<module>.pb console :
;    IncludeFile "../mcp_common/runtime.pbi"
;    IncludeFile "../tests/unit_test.pbi"
;    ... tests avec UTAssert / UTAssertStr ...
;    UTFinalize()   ; rapport + code de sortie (0 = tout passe)
; ============================================================================

Global G_UTPassed.i = 0
Global G_UTFailed.i = 0

; Compare deux entiers (ou booleens)
Procedure UTAssert(Expected.i, Actual.i, Name.s)
  If Expected = Actual
    G_UTPassed + 1
    SendStderrLine("[OK]   " + Name)
  Else
    G_UTFailed + 1
    SendStderrLine("[FAIL] " + Name + " (attendu=" + Str(Expected) + ", reel=" + Str(Actual) + ")")
  EndIf
EndProcedure

; Compare deux chaines
Procedure UTAssertStr(Expected.s, Actual.s, Name.s)
  If Expected = Actual
    G_UTPassed + 1
    SendStderrLine("[OK]   " + Name)
  Else
    G_UTFailed + 1
    SendStderrLine("[FAIL] " + Name + " (attendu=" + Chr(34) + Expected + Chr(34) + ", reel=" + Chr(34) + Actual + Chr(34) + ")")
  EndIf
EndProcedure

; Verifie qu'une chaine contient une sous-chaine
Procedure UTAssertContains(Haystack.s, Needle.s, Name.s)
  If FindString(Haystack, Needle) > 0
    G_UTPassed + 1
    SendStderrLine("[OK]   " + Name)
  Else
    G_UTFailed + 1
    SendStderrLine("[FAIL] " + Name + " (" + Chr(34) + Needle + Chr(34) + " absent de " + Chr(34) + Left(Haystack, 80) + Chr(34) + ")")
  EndIf
EndProcedure

; Rapport final ; End 1 si au moins un echec
Procedure UTFinalize()
  SendStderrLine("---")
  SendStderrLine("Tests unitaires : " + Str(G_UTPassed) + " reussis, " + Str(G_UTFailed) + " echoues")
  If G_UTFailed > 0
    End 1
  EndIf
EndProcedure
