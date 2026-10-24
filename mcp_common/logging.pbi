; ============================================================================
;  logging.pbi - Journalisation sur stderr pour les serveurs MCP
;  Depend de runtime.pbi (SendStderrLine). Jamais sur stdout : le serveur
;  HTTP n'ecrit rien sur la sortie standard.
; ============================================================================
;  A inclure apres runtime.pbi :
;    IncludeFile "../mcp_common/runtime.pbi"
;    IncludeFile "../mcp_common/logging.pbi"
; ============================================================================

Procedure LogLine(Level.s, Msg.s)
  SendStderrLine("[" + FormatDate("%HH:%II:%SS", Date()) + "] [" + Level + "] " + Msg)
EndProcedure

Procedure LogDebug(Msg.s)
  LogLine("DEBUG", Msg)
EndProcedure

Procedure LogError(Msg.s)
  LogLine("ERROR", Msg)
EndProcedure
