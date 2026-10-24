; ============================================================================
;  test_github.pb - Tests unitaires du serveur GitHub (Phase 5)
;  T5.1-T5.15 hors ligne : validation, pagination, garde confirm, mapping
;  d'erreurs, en-tetes. Les appels API sont couverts par l'integration
;  (tests/test_mcp.py avec tests/mock_github.py).
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/http.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../src/github_core.pbi"
IncludeFile "unit_test.pbi"

Procedure Test_Segments()
  SendStderrLine("--- validation owner/repo/ref ---")
  UTAssert(1, GhSafeSegment("mickael-cala"), "owner avec tiret accepte")
  UTAssert(1, GhSafeSegment("MCP-file-PB"), "repo avec tirets accepte")
  UTAssert(0, GhSafeSegment(""), "segment vide refuse")
  UTAssert(0, GhSafeSegment("a/b"), "slash refuse")
  UTAssert(0, GhSafeSegment("a b"), "espace refuse")
  UTAssert(0, GhSafeSegment("a?b"), "? refuse")
  UTAssert(0, GhSafeSegment("a#b"), "# refuse")
  UTAssert(0, GhSafeSegment("a" + #LF$ + "b"), "retour ligne refuse")
EndProcedure

Procedure Test_Pagination()
  SendStderrLine("--- pagination ---")
  UTAssert(1, GhClampPage(0), "page 0 -> 1")
  UTAssert(1, GhClampPage(-5), "page negative -> 1")
  UTAssert(7, GhClampPage(7), "page 7 conservee")
  UTAssert(30, GhClampPerPage(0), "per_page 0 -> 30")
  UTAssert(30, GhClampPerPage(-1), "per_page negatif -> 30")
  UTAssert(100, GhClampPerPage(500), "per_page 500 -> 100")
  UTAssert(15, GhClampPerPage(15), "per_page 15 conserve")
EndProcedure

Procedure Test_Headers()
  SendStderrLine("--- en-tetes ---")
  G_GhToken = "ctx-test-token"
  Protected H.s = GhHeaders(#False)
  UTAssert(1, Bool(FindString(H, "Accept: application/vnd.github+json") > 0), "Accept present")
  UTAssert(1, Bool(FindString(H, "X-GitHub-Api-Version: 2022-11-28") > 0), "version API presente")
  UTAssert(1, Bool(FindString(H, "User-Agent:") > 0), "User-Agent present")
  UTAssert(1, Bool(FindString(H, "Authorization: Bearer ctx-test-token") > 0), "Authorization avec token")
  UTAssert(0, Bool(FindString(GhHeaders(#False), "Content-Type") > 0), "pas de Content-Type en GET")
  UTAssert(1, Bool(FindString(GhHeaders(#True), "Content-Type: application/json") > 0), "Content-Type en POST")
  G_GhToken = ""
EndProcedure

Procedure Test_ErrorMapping()
  SendStderrLine("--- mapping d'erreurs ---")
  UTAssert(1, Bool(FindString(GhErrorText(401, ""), "token invalide") > 0), "401 -> token invalide")
  UTAssert(1, Bool(FindString(GhErrorText(404, ""), "introuvable") > 0), "404 -> introuvable")
  UTAssert(1, Bool(FindString(GhErrorText(422, ""), "validation") > 0), "422 -> validation")
  UTAssert(1, Bool(FindString(GhErrorText(500, ""), "indisponible") > 0), "500 -> indisponible")
  UTAssert(1, Bool(FindString(GhErrorText(403, "API rate limit exceeded"), "limite de taux") > 0), "403 rate limit -> quota")
  UTAssert(1, Bool(FindString(GhErrorText(403, "Forbidden"), "acces refuse") > 0), "403 simple -> acces refuse")
  UTAssert(1, Bool(FindString(GhErrorText(429, ""), "429") > 0), "429 -> quota")
  UTAssert(1, Bool(FindString(GhErrorText(-1, ""), "echec reseau") > 0), "-1 -> reseau")
  UTAssertStr("", GhErrorText(200, "{}"), "200 -> pas d'erreur")

  ; message JSON extrait et joint
  Protected Msg.s = GhErrorText(422, ~"{\"message\":\"Validation Failed\"}")
  UTAssert(1, Bool(FindString(Msg, "Validation Failed") > 0), "message JSON joint")
EndProcedure

Procedure Test_ConfirmGuard()
  SendStderrLine("--- garde confirm ---")
  G_GhToken = "faux-token-pour-tests"   ; evite le court-circuit token manquant
  Protected Out.s = ToolGhCreateIssue("owner", "repo", "titre", "corps", #False)
  UTAssert(1, Bool(FindString(Out, "non confirmee") > 0), "create_issue sans confirm -> refus")
  UTAssert(0, Bool(FindString(Out, "Erreur GitHub") > 0), "aucun appel API effectue")

  Out = ToolGhCreatePullRequest("owner", "repo", "titre", "head", "main", "", #False)
  UTAssert(1, Bool(FindString(Out, "non confirmee") > 0), "create_pull_request sans confirm -> refus")

  ; validations d'arguments sans reseau (token absent -> erreur token d'abord)
  G_GhToken = ""
  Out = ToolGhCreateIssue("owner", "repo", "", "", #True)
  UTAssert(1, Bool(FindString(Out, "MCP_GITHUB_TOKEN") > 0), "sans token -> erreur explicite")
  G_GhToken = "faux-token-pour-tests"
  Out = ToolGhCreateIssue("owner/repo", "repo", "titre", "", #True)
  UTAssert(1, Bool(FindString(Out, "owner/repo invalides") > 0), "owner invalide -> erreur")
  Out = ToolGhCreateIssue("owner", "repo", "", "", #True)
  UTAssert(1, Bool(FindString(Out, "title") > 0), "titre vide -> erreur")
  G_GhToken = ""
EndProcedure

Procedure Test_JsonExtraction()
  SendStderrLine("--- extraction message JSON ---")
  UTAssertStr("Not Found", GhJsonMessage(~"{\"message\":\"Not Found\"}"), "message extrait")
  UTAssertStr("", GhJsonMessage("pas du json"), "JSON invalide -> vide")
  UTAssertStr("", GhJsonMessage(~"{\"autre\":1}"), "sans champ message -> vide")
EndProcedure

; ===========================================================================
; Programme principal
; ===========================================================================
If Not CheckRuntime()
  End 1
EndIf

Test_Segments()
Test_Pagination()
Test_Headers()
Test_ErrorMapping()
Test_ConfirmGuard()
Test_JsonExtraction()

UTFinalize()

End
