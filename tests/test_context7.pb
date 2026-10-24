; ============================================================================
;  test_context7.pb - Tests unitaires du serveur Context7 (Phase 3)
;  Hors ligne : encodage URL, mapping d'erreurs, garde-fous, troncature.
;  Les tests live (T3.1-T3.3) sont dans tests/test_mcp.py.
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/http.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../src/context7_core.pbi"
IncludeFile "unit_test.pbi"

Procedure Test_UrlEncode()
  SendStderrLine("--- UrlEncodeComponent ---")
  UTAssertStr("react", UrlEncodeComponent("react"), "alphanumeriques inchanges")
  UTAssertStr("a%20b", UrlEncodeComponent("a b"), "espace -> %20")
  UTAssertStr("a%26b%3Dc", UrlEncodeComponent("a&b=c"), "& et = encodes")
  UTAssertStr("caf%C3%A9", UrlEncodeComponent("café"), "UTF-8 multi-octets")
  UTAssertStr("a%2Fb", UrlEncodeComponent("a/b"), "slash encode (composant)")
  UTAssertStr("a-b_c.d~e", UrlEncodeComponent("a-b_c.d~e"), " - _ . ~ conserves")
EndProcedure

Procedure Test_HttpErrorText()
  SendStderrLine("--- C7HttpErrorText ---")
  UTAssert(1, Bool(FindString(C7HttpErrorText(-1, "P"), "echec reseau") > 0), "-1 -> echec reseau")
  UTAssert(1, Bool(FindString(C7HttpErrorText(-2, "P"), "curl") > 0), "-2 -> couche HTTP indisponible (curl)")
  UTAssert(1, Bool(FindString(C7HttpErrorText(401, "P"), "401") > 0), "401 -> cle invalide")
  UTAssert(1, Bool(FindString(C7HttpErrorText(429, "P"), "quota") > 0), "429 -> quota depasse")
  UTAssert(1, Bool(FindString(C7HttpErrorText(500, "P"), "indisponible") > 0), "5xx -> indisponible")
  UTAssert(1, Bool(FindString(C7HttpErrorText(502, "P"), "indisponible") > 0), "502 -> indisponible")
  UTAssert(1, Bool(FindString(C7HttpErrorText(404, "P"), "404") > 0), "404 -> introuvable")
  UTAssert(1, Bool(FindString(C7HttpErrorText(400, "P"), "400") > 0), "400 -> erreur HTTP")
  UTAssertStr("", C7HttpErrorText(200, "P"), "200 -> pas d'erreur")
EndProcedure

Procedure Test_Guards()
  SendStderrLine("--- garde-fous ---")
  UTAssert(1, Bool(Left(ToolResolveLibraryId("", "oss"), 6) = "Erreur"), "resolve avec query vide -> erreur")
  UTAssert(1, Bool(Left(ToolQueryDocs("", "x", 100, "", 100), 6) = "Erreur"), "docs sans libraryId -> erreur")

  ; Sans cle configuree : message explicite avant tout appel reseau
  G_C7ApiKey = ""
  Protected Out.s = ToolQueryDocs("/react/react", "hooks", 100, "", 100)
  UTAssert(1, Bool(FindString(Out, "MCP_CONTEXT7_API_KEY") > 0), "docs sans cle -> consigne explicite")
EndProcedure

Procedure Test_BuildUrl()
  SendStderrLine("--- construction URL ---")
  ; Verifiee indirectement : Url valide encodee (pas d'espace brut)
  Protected Enc.s = UrlEncodeComponent("app router")
  UTAssertStr("app%20router", Enc, "query docs encodee")
EndProcedure

; ===========================================================================
; Programme principal
; ===========================================================================
If Not CheckRuntime()
  End 1
EndIf

Test_UrlEncode()
Test_HttpErrorText()
Test_Guards()
Test_BuildUrl()

UTFinalize()

End
