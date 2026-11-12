; ============================================================================
;  github_core.pbi - Coeur metier du serveur MCP GitHub (API REST v3)
;  Inclus par src/githubMCP.pb et tests/test_github.pb.
; ============================================================================
;  Config :
;    MCP_GITHUB_TOKEN     = token (scope minimal ; requis par tous les outils)
;    MCP_GITHUB_API_BASE  = base API (defaut https://api.github.com ; sert
;                           aux tests avec un serveur mock local)
;  Les ecritures (create_issue / create_pull_request) exigent confirm=true.
; ============================================================================

Global G_GhToken.s = ""
Global G_GhApiBase.s = "https://api.github.com"

#GH_MAX_PER_PAGE = 100
; Plafond de taille des reponses API (audit I5) : le plus gros JSON
; legitime (per_page=100) reste tres en dessous.
#GH_MAX_RESPONSE_BYTES = 4 * 1024 * 1024

; ---------------------------------------------------------------------------
; Validation / echappement
; ---------------------------------------------------------------------------

; Valide un segment d'URL (owner, repo, ref, sha) : non vide, sans espace
; ni caractere de controle ni separateur de chemin.
Procedure.i GhSafeSegment(S.s)
  If S = "" : ProcedureReturn #False : EndIf
  If FindString(S, "/") > 0 Or FindString(S, "\\") > 0 : ProcedureReturn #False : EndIf
  If FindString(S, " ") > 0 Or FindString(S, #LF$) > 0 Or FindString(S, #CR$) > 0
    ProcedureReturn #False
  EndIf
  If FindString(S, "?") > 0 Or FindString(S, "#") > 0 : ProcedureReturn #False : EndIf
  ProcedureReturn #True
EndProcedure

Procedure.i GhClampPerPage(N.i)
  If N <= 0 : N = 30 : EndIf
  If N > #GH_MAX_PER_PAGE : N = #GH_MAX_PER_PAGE : EndIf
  ProcedureReturn N
EndProcedure

Procedure.i GhClampPage(N.i)
  If N < 1 : N = 1 : EndIf
  ProcedureReturn N
EndProcedure

; ---------------------------------------------------------------------------
; Requete API
; ---------------------------------------------------------------------------

; Construit l'en-tete HTTP pour GitHub.
Procedure.s GhHeaders(WithContentType.i)
  Protected H.s = "Accept: application/vnd.github+json" + #CRLF$ +
                  "X-GitHub-Api-Version: 2022-11-28" + #CRLF$ +
                  "User-Agent: MCP-GitHub-PureBasic/1.0"
  If WithContentType
    H + #CRLF$ + "Content-Type: application/json"
  EndIf
  If G_GhToken <> ""
    H + #CRLF$ + "Authorization: Bearer " + G_GhToken
  EndIf
  ProcedureReturn H
EndProcedure

; Extrait le champ "message" d'une reponse d'erreur JSON GitHub.
Procedure.s GhJsonMessage(Body.s)
  Protected J.i = ParseJSON(#PB_Any, Body)
  If J = 0 : ProcedureReturn "" : EndIf
  Protected Root.i = JSONValue(J)
  Protected Msg.s = ""
  If JSONType(Root) = #PB_JSON_Object
    Protected M.i = GetJSONMember(Root, "message")
    If M And JSONType(M) = #PB_JSON_String
      Msg = GetJSONString(M)
    EndIf
  EndIf
  FreeJSON(J)
  ProcedureReturn Msg
EndProcedure

; Mapping d'un statut d'erreur GitHub en message clair.
Procedure.s GhErrorText(Status.i, Body.s)
  If Status >= 200 And Status < 300
    ProcedureReturn ""
  EndIf
  Protected Detail.s = GhJsonMessage(Body)
  Protected Msg.s
  Select Status
    Case -2
      Msg = "Erreur GitHub : curl est introuvable sur cet OS (necessaire pour l'authentification HTTP)."
    Case -1
      Msg = "Erreur GitHub : echec reseau (DNS, connexion ou timeout)."
    Case 401
      Msg = "Erreur GitHub : token invalide ou expire (401). Verifier MCP_GITHUB_TOKEN."
    Case 403
      If FindString(LCase(Body), "rate limit") > 0
        Msg = "Erreur GitHub : limite de taux depassee (403). Reessayer plus tard ou utiliser un token."
      Else
        Msg = "Erreur GitHub : acces refuse (403)."
      EndIf
    Case 404
      Msg = "Erreur GitHub : ressource introuvable (404). Verifier owner/repo/numero."
    Case 422
      Msg = "Erreur GitHub : validation echouee (422)."
    Case 429
      Msg = "Erreur GitHub : limite de taux depassee (429). Reessayer plus tard."
    Default
      If Status >= 500
        Msg = "Erreur GitHub : API indisponible (" + Str(Status) + ")."
      Else
        Msg = "Erreur GitHub : erreur HTTP " + Str(Status) + "."
      EndIf
  EndSelect
  If Detail <> ""
    Msg + " " + Detail
  EndIf
  ProcedureReturn Msg
EndProcedure

; GET JSON. Retourne (statut, corps) ; en cas de succes le JSON est valide.
; Reponse plafonnee (audit I5) : le plus gros JSON legitime (per_page=100)
; reste tres en dessous de 4 Mio.
Procedure.s GhGet(Path.s, *Status.Integer)
  *Status\i = -1
  If G_GhToken = ""
    *Status\i = -3
    ProcedureReturn ""
  EndIf
  ProcedureReturn HttpGetLimited(G_GhApiBase + Path, GhHeaders(#False), 20, #GH_MAX_RESPONSE_BYTES, *Status)
EndProcedure

; POST JSON (Body deja serialise). Retourne (statut, corps).
Procedure.s GhPost(Path.s, Body.s, *Status.Integer)
  *Status\i = -1
  If G_GhToken = ""
    *Status\i = -3
    ProcedureReturn ""
  EndIf
  ProcedureReturn HttpPostLimited(G_GhApiBase + Path, GhHeaders(#True), Body, 20, #GH_MAX_RESPONSE_BYTES, *Status)
EndProcedure

; Verifie token configure, sinon message pret a renvoyer.
Procedure.s GhCheckToken()
  If G_GhToken = ""
    ProcedureReturn "Erreur GitHub : MCP_GITHUB_TOKEN non configure cote serveur."
  EndIf
  ProcedureReturn ""
EndProcedure

; Finalise une reponse : JSON valide ou message d'erreur.
Procedure.s GhFinish(Status.i, Body.s, Context.s)
  If Status = -3
    ProcedureReturn "Erreur GitHub : MCP_GITHUB_TOKEN non configure cote serveur."
  EndIf
  If Status = -4
    ProcedureReturn "Erreur GitHub : reponse trop volumineuse (plafond interne)."
  EndIf
  If Status < 200 Or Status >= 300
    ProcedureReturn GhErrorText(Status, Body)
  EndIf
  Protected J.i = ParseJSON(#PB_Any, Body)
  If J = 0
    ProcedureReturn "Erreur : reponse GitHub invalide (JSON illisible) pour " + Context + "."
  EndIf
  FreeJSON(J)
  ProcedureReturn Body
EndProcedure

; ---------------------------------------------------------------------------
; Outils MCP
; ---------------------------------------------------------------------------

Procedure.s ToolGhGetRepo(Owner.s, Repo.s)
  Protected Bad.s = GhCheckToken()
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Not GhSafeSegment(Owner) Or Not GhSafeSegment(Repo)
    ProcedureReturn "Erreur : owner/repo invalides."
  EndIf
  Protected Status.i
  Protected Body.s = GhGet("/repos/" + UrlEncodeComponent(Owner) + "/" + UrlEncodeComponent(Repo), @Status)
  ProcedureReturn GhFinish(Status, Body, "le depot")
EndProcedure

Procedure.s ToolGhListIssues(Owner.s, Repo.s, State.s, Page.i, PerPage.i)
  Protected Bad.s = GhCheckToken()
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Not GhSafeSegment(Owner) Or Not GhSafeSegment(Repo)
    ProcedureReturn "Erreur : owner/repo invalides."
  EndIf
  Protected St.s = LCase(Trim(State))
  If St = "" : St = "open" : EndIf
  If St <> "open" And St <> "closed" And St <> "all"
    ProcedureReturn "Erreur : state doit etre open, closed ou all."
  EndIf
  Protected PageN.i = GhClampPage(Page), PP.i = GhClampPerPage(PerPage)
  Protected Status.i
  Protected Body.s = GhGet("/repos/" + UrlEncodeComponent(Owner) + "/" + UrlEncodeComponent(Repo) +
                           "/issues?state=" + St + "&page=" + Str(PageN) + "&per_page=" + Str(PP), @Status)
  ProcedureReturn GhFinish(Status, Body, "les issues")
EndProcedure

Procedure.s ToolGhGetIssue(Owner.s, Repo.s, Number.i)
  Protected Bad.s = GhCheckToken()
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Not GhSafeSegment(Owner) Or Not GhSafeSegment(Repo)
    ProcedureReturn "Erreur : owner/repo invalides."
  EndIf
  If Number < 1 : ProcedureReturn "Erreur : 'number' doit etre >= 1." : EndIf
  Protected Status.i
  Protected Body.s = GhGet("/repos/" + UrlEncodeComponent(Owner) + "/" + UrlEncodeComponent(Repo) +
                           "/issues/" + Str(Number), @Status)
  ProcedureReturn GhFinish(Status, Body, "l'issue")
EndProcedure

; Serialise un objet {title, body} en JSON
Procedure.s GhIssueBody(Title.s, BodyText.s)
  Protected J.i = CreateJSON(#PB_Any)
  Protected Root.i = SetJSONObject(JSONValue(J))
  SetJSONString(AddJSONMember(Root, "title"), Title)
  SetJSONString(AddJSONMember(Root, "body"), BodyText)
  Protected Out.s = ComposeJSON(J)
  FreeJSON(J)
  ProcedureReturn Out
EndProcedure

Procedure.s ToolGhCreateIssue(Owner.s, Repo.s, Title.s, BodyText.s, Confirm.i)
  Protected Bad.s = GhCheckToken()
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Not GhSafeSegment(Owner) Or Not GhSafeSegment(Repo)
    ProcedureReturn "Erreur : owner/repo invalides."
  EndIf
  If Trim(Title) = ""
    ProcedureReturn "Erreur : 'title' est requis."
  EndIf
  If Not Confirm
    ProcedureReturn "Erreur : creation d'issue non confirmee (confirm=true requis)."
  EndIf
  Protected Status.i
  Protected Body.s = GhPost("/repos/" + UrlEncodeComponent(Owner) + "/" + UrlEncodeComponent(Repo) + "/issues",
                            GhIssueBody(Title, BodyText), @Status)
  ProcedureReturn GhFinish(Status, Body, "la creation d'issue")
EndProcedure

Procedure.s ToolGhListPullRequests(Owner.s, Repo.s, State.s, Page.i, PerPage.i)
  Protected Bad.s = GhCheckToken()
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Not GhSafeSegment(Owner) Or Not GhSafeSegment(Repo)
    ProcedureReturn "Erreur : owner/repo invalides."
  EndIf
  Protected St.s = LCase(Trim(State))
  If St = "" : St = "open" : EndIf
  If St <> "open" And St <> "closed" And St <> "all"
    ProcedureReturn "Erreur : state doit etre open, closed ou all."
  EndIf
  Protected PageN.i = GhClampPage(Page), PP.i = GhClampPerPage(PerPage)
  Protected Status.i
  Protected Body.s = GhGet("/repos/" + UrlEncodeComponent(Owner) + "/" + UrlEncodeComponent(Repo) +
                           "/pulls?state=" + St + "&page=" + Str(PageN) + "&per_page=" + Str(PP), @Status)
  ProcedureReturn GhFinish(Status, Body, "les pull requests")
EndProcedure

Procedure.s ToolGhGetPullRequest(Owner.s, Repo.s, Number.i)
  Protected Bad.s = GhCheckToken()
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Not GhSafeSegment(Owner) Or Not GhSafeSegment(Repo)
    ProcedureReturn "Erreur : owner/repo invalides."
  EndIf
  If Number < 1 : ProcedureReturn "Erreur : 'number' doit etre >= 1." : EndIf
  Protected Status.i
  Protected Body.s = GhGet("/repos/" + UrlEncodeComponent(Owner) + "/" + UrlEncodeComponent(Repo) +
                           "/pulls/" + Str(Number), @Status)
  ProcedureReturn GhFinish(Status, Body, "la pull request")
EndProcedure

Procedure.s GhPullRequestBody(Title.s, Head.s, Base.s, BodyText.s)
  Protected J.i = CreateJSON(#PB_Any)
  Protected Root.i = SetJSONObject(JSONValue(J))
  SetJSONString(AddJSONMember(Root, "title"), Title)
  SetJSONString(AddJSONMember(Root, "head"), Head)
  SetJSONString(AddJSONMember(Root, "base"), Base)
  SetJSONString(AddJSONMember(Root, "body"), BodyText)
  Protected Out.s = ComposeJSON(J)
  FreeJSON(J)
  ProcedureReturn Out
EndProcedure

Procedure.s ToolGhCreatePullRequest(Owner.s, Repo.s, Title.s, Head.s, Base.s, BodyText.s, Confirm.i)
  Protected Bad.s = GhCheckToken()
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Not GhSafeSegment(Owner) Or Not GhSafeSegment(Repo) Or Not GhSafeSegment(Head) Or Not GhSafeSegment(Base)
    ProcedureReturn "Erreur : owner/repo/head/base invalides."
  EndIf
  If Trim(Title) = ""
    ProcedureReturn "Erreur : 'title' est requis."
  EndIf
  If Not Confirm
    ProcedureReturn "Erreur : creation de pull request non confirmee (confirm=true requis)."
  EndIf
  Protected Status.i
  Protected Body.s = GhPost("/repos/" + UrlEncodeComponent(Owner) + "/" + UrlEncodeComponent(Repo) + "/pulls",
                            GhPullRequestBody(Title, Head, Base, BodyText), @Status)
  ProcedureReturn GhFinish(Status, Body, "la creation de pull request")
EndProcedure

Procedure.s ToolGhListCommits(Owner.s, Repo.s, Sha.s, Page.i, PerPage.i)
  Protected Bad.s = GhCheckToken()
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Not GhSafeSegment(Owner) Or Not GhSafeSegment(Repo)
    ProcedureReturn "Erreur : owner/repo invalides."
  EndIf
  If Sha <> "" And Not GhSafeSegment(Sha)
    ProcedureReturn "Erreur : 'sha' invalide."
  EndIf
  Protected PageN.i = GhClampPage(Page), PP.i = GhClampPerPage(PerPage)
  Protected Status.i
  Protected Path.s = "/repos/" + UrlEncodeComponent(Owner) + "/" + UrlEncodeComponent(Repo) +
                     "/commits?page=" + Str(PageN) + "&per_page=" + Str(PP)
  If Sha <> ""
    Path + "&sha=" + UrlEncodeComponent(Sha)
  EndIf
  Protected Body.s = GhGet(Path, @Status)
  ProcedureReturn GhFinish(Status, Body, "les commits")
EndProcedure

Procedure.s ToolGhSearchCode(Query.s, Page.i, PerPage.i)
  Protected Bad.s = GhCheckToken()
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Trim(Query) = ""
    ProcedureReturn "Erreur : 'query' ne peut pas etre vide."
  EndIf
  Protected PageN.i = GhClampPage(Page), PP.i = GhClampPerPage(PerPage)
  Protected Status.i
  Protected Body.s = GhGet("/search/code?q=" + UrlEncodeComponent(Query) +
                           "&page=" + Str(PageN) + "&per_page=" + Str(PP), @Status)
  ProcedureReturn GhFinish(Status, Body, "la recherche de code")
EndProcedure

Procedure.s ToolGhSearchRepositories(Query.s, Page.i, PerPage.i)
  Protected Bad.s = GhCheckToken()
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Trim(Query) = ""
    ProcedureReturn "Erreur : 'query' ne peut pas etre vide."
  EndIf
  Protected PageN.i = GhClampPage(Page), PP.i = GhClampPerPage(PerPage)
  Protected Status.i
  Protected Body.s = GhGet("/search/repositories?q=" + UrlEncodeComponent(Query) +
                           "&page=" + Str(PageN) + "&per_page=" + Str(PP), @Status)
  ProcedureReturn GhFinish(Status, Body, "la recherche de depots")
EndProcedure

; ---------------------------------------------------------------------------
; Catalogue MCP
; ---------------------------------------------------------------------------
Procedure.i GhBuildCatalog()
  Protected RootJSON.i = CreateJSON(#PB_Any)
  Protected RootVal.i = SetJSONObject(JSONValue(RootJSON))
  Protected ToolsArr.i = AddJSONMember(RootVal, "tools")
  SetJSONArray(ToolsArr)

  ToolDef(ToolsArr, "gh_get_repo", "Metadonnees d'un depot GitHub.", "owner|string|Proprietaire;repo|string|Nom du depot", "owner;repo")
  ToolDef(ToolsArr, "gh_list_issues", "Liste les issues d'un depot (pagine).", "owner|string|Proprietaire;repo|string|Depot;state|string|open (defaut), closed, all;page|integer|Page (defaut: 1);per_page|integer|Elements par page (defaut: 30, max: 100)", "owner;repo")
  ToolDef(ToolsArr, "gh_get_issue", "Detail d'une issue.", "owner|string|Proprietaire;repo|string|Depot;number|integer|Numero d'issue", "owner;repo;number")
  ToolDef(ToolsArr, "gh_create_issue", "Cree une issue (exige confirm=true).", "owner|string|Proprietaire;repo|string|Depot;title|string|Titre;body|string|Corps;confirm|boolean|Doit valoir true", "owner;repo;title;confirm")
  ToolDef(ToolsArr, "gh_list_pull_requests", "Liste les pull requests (pagine).", "owner|string|Proprietaire;repo|string|Depot;state|string|open (defaut), closed, all;page|integer|Page;per_page|integer|Par page", "owner;repo")
  ToolDef(ToolsArr, "gh_get_pull_request", "Detail d'une pull request.", "owner|string|Proprietaire;repo|string|Depot;number|integer|Numero de PR", "owner;repo;number")
  ToolDef(ToolsArr, "gh_create_pull_request", "Cree une pull request (exige confirm=true).", "owner|string|Proprietaire;repo|string|Depot;title|string|Titre;head|string|Branche source;base|string|Branche cible;body|string|Corps;confirm|boolean|Doit valoir true", "owner;repo;title;head;base;confirm")
  ToolDef(ToolsArr, "gh_list_commits", "Liste les commits (pagine, sha optionnel).", "owner|string|Proprietaire;repo|string|Depot;sha|string|Branche ou commit de depart;page|integer|Page;per_page|integer|Par page", "owner;repo")
  ToolDef(ToolsArr, "gh_search_code", "Recherche du code sur GitHub.", "query|string|Requete (syntaxe GitHub);page|integer|Page;per_page|integer|Par page", "query")
  ToolDef(ToolsArr, "gh_search_repositories", "Recherche des depots GitHub.", "query|string|Requete (syntaxe GitHub);page|integer|Page;per_page|integer|Par page", "query")

  ProcedureReturn RootJSON
EndProcedure

; ---------------------------------------------------------------------------
; Dispatch des outils (hook *G_ToolHandler)
; ---------------------------------------------------------------------------
Procedure.s GhDispatch(ToolName.s, ArgsObj.i, *IsError.Integer)
  Select ToolName
    Case "gh_get_repo"
      ProcedureReturn ToolGhGetRepo(GetArgString(ArgsObj, "owner"), GetArgString(ArgsObj, "repo"))
    Case "gh_list_issues"
      ProcedureReturn ToolGhListIssues(GetArgString(ArgsObj, "owner"), GetArgString(ArgsObj, "repo"), GetArgString(ArgsObj, "state"), GetArgInt(ArgsObj, "page", 1), GetArgInt(ArgsObj, "per_page", 30))
    Case "gh_get_issue"
      ProcedureReturn ToolGhGetIssue(GetArgString(ArgsObj, "owner"), GetArgString(ArgsObj, "repo"), GetArgInt(ArgsObj, "number", 0))
    Case "gh_create_issue"
      ProcedureReturn ToolGhCreateIssue(GetArgString(ArgsObj, "owner"), GetArgString(ArgsObj, "repo"), GetArgString(ArgsObj, "title"), GetArgString(ArgsObj, "body"), GetArgBool(ArgsObj, "confirm", 0))
    Case "gh_list_pull_requests"
      ProcedureReturn ToolGhListPullRequests(GetArgString(ArgsObj, "owner"), GetArgString(ArgsObj, "repo"), GetArgString(ArgsObj, "state"), GetArgInt(ArgsObj, "page", 1), GetArgInt(ArgsObj, "per_page", 30))
    Case "gh_get_pull_request"
      ProcedureReturn ToolGhGetPullRequest(GetArgString(ArgsObj, "owner"), GetArgString(ArgsObj, "repo"), GetArgInt(ArgsObj, "number", 0))
    Case "gh_create_pull_request"
      ProcedureReturn ToolGhCreatePullRequest(GetArgString(ArgsObj, "owner"), GetArgString(ArgsObj, "repo"), GetArgString(ArgsObj, "title"), GetArgString(ArgsObj, "head"), GetArgString(ArgsObj, "base"), GetArgString(ArgsObj, "body"), GetArgBool(ArgsObj, "confirm", 0))
    Case "gh_list_commits"
      ProcedureReturn ToolGhListCommits(GetArgString(ArgsObj, "owner"), GetArgString(ArgsObj, "repo"), GetArgString(ArgsObj, "sha"), GetArgInt(ArgsObj, "page", 1), GetArgInt(ArgsObj, "per_page", 30))
    Case "gh_search_code"
      ProcedureReturn ToolGhSearchCode(GetArgString(ArgsObj, "query"), GetArgInt(ArgsObj, "page", 1), GetArgInt(ArgsObj, "per_page", 30))
    Case "gh_search_repositories"
      ProcedureReturn ToolGhSearchRepositories(GetArgString(ArgsObj, "query"), GetArgInt(ArgsObj, "page", 1), GetArgInt(ArgsObj, "per_page", 30))
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect
EndProcedure
