; ============================================================================
;  http_guard.pbi - Verifications de securite applicatives par requete.
;  Inclus par http_server.pbi (apres les globals de configuration) :
;    Origin, Host (anti DNS rebinding), comparaison a temps constant du
;    jeton/secret, limitation de debit et blocage anti brute-force.
;  Raison de la scission : limite PureBasic Free (~800 lignes/source).
; ============================================================================
; ---------------------------------------------------------------------------
; Verifications de securite
; ---------------------------------------------------------------------------
Procedure.i HttpOriginAllowed(Origin.s)
  If Origin = "" : ProcedureReturn #True : EndIf
  Protected O.s = LCase(Trim(Origin))
  Protected P.s = Str(G_HttpPort)
  If O = "http://127.0.0.1:" + P Or O = "http://localhost:" + P Or O = "http://[::1]:" + P
    ProcedureReturn #True
  EndIf
  If G_HttpAllowedOrigins <> ""
    Protected i.i, n.i = CountString(G_HttpAllowedOrigins, ",") + 1, A.s
    For i = 1 To n
      A = LCase(Trim(StringField(G_HttpAllowedOrigins, i, ",")))
      If A <> "" And O = A : ProcedureReturn #True : EndIf
    Next
  EndIf
  ProcedureReturn #False
EndProcedure
; Host autorise ? (anti DNS rebinding) : un navigateur piege par un domaine
; re-resolu vers 127.0.0.1 envoie Host: pirate sur /mcp — le controle Origin
; ne s'applique pas aux requetes sans Origin. Host absent = client HTTP/1.0
; legacy (le vecteur rebinding exige un Host controle par l'attaquant).
; Accepte : formes loopback (avec ou sans port), hote d'ecoute explicite,
; et la liste MCP_HTTP_ALLOWED_HOSTS (separee par virgules).
Procedure.i HttpHostAllowed(Host.s)
  Protected H.s = LCase(Trim(Host))
  If H = "" : ProcedureReturn #True : EndIf
  Protected P.s = Str(G_HttpPort)
  If H = "127.0.0.1:" + P Or H = "127.0.0.1" Or H = "localhost:" + P Or H = "localhost" Or H = "[::1]:" + P Or H = "[::1]"
    ProcedureReturn #True
  EndIf
  Protected B.s = LCase(G_HttpHost)
  If B <> "127.0.0.1" And B <> "::1" And B <> ""
    If H = B + ":" + P Or H = B : ProcedureReturn #True : EndIf
  EndIf
  If G_HttpAllowedHosts <> ""
    Protected i.i, n.i = CountString(G_HttpAllowedHosts, ",") + 1, A.s
    For i = 1 To n
      A = LCase(Trim(StringField(G_HttpAllowedHosts, i, ",")))
      If A <> "" And (H = A Or H = A + ":" + P)
        ProcedureReturn #True
      EndIf
    Next
  EndIf
  ProcedureReturn #False
EndProcedure

; Comparaison a temps constant (audit niveau 2) : aucune sortie anticipee,
; XOR accumule sur max(longueurs) octets — un attaquant reseau ne peut pas
; deviner le jeton/secret caractere par caractere via le temps de reponse.
Procedure.i HttpConstCompare(A.s, B.s)
  Protected La.i = Len(A), Lb.i = Len(B)
  Protected L.i = La
  If Lb > L : L = Lb : EndIf
  Protected Diff.i = La ! Lb          ; longueurs differentes -> non nul
  Protected i.i, c1.i, c2.i
  For i = 1 To L
    c1 = 0 : c2 = 0
    If i <= La : c1 = Asc(Mid(A, i, 1)) : EndIf
    If i <= Lb : c2 = Asc(Mid(B, i, 1)) : EndIf
    Diff | (c1 ! c2)
  Next
  ProcedureReturn Bool(Diff = 0)
EndProcedure

; Fenetres de limitation : retourne #True si la requete /mcp doit etre
; rejetee en 429 (plafond de debit atteint, ou blocage anti brute-force
; actif). /health est exempt ; le debit ne compte que les appels /mcp.
Procedure.i HttpRateLimited()
  Protected Now.i = ElapsedMilliseconds()
  If G_HttpRateMax > 0
    If Now - G_HttpRateWindowStart >= 10000
      G_HttpRateWindowStart = Now
      G_HttpRateCount = 0
    EndIf
    G_HttpRateCount + 1
    If G_HttpRateCount > G_HttpRateMax
      ProcedureReturn #True
    EndIf
  EndIf
  If G_HttpAuthMaxFail > 0 And G_HttpAuthLock > 0
    If Now < G_HttpAuthLock
      ProcedureReturn #True
    EndIf
    G_HttpAuthLock = 0
    G_HttpAuthFailCount = 0
  EndIf
  ProcedureReturn #False
EndProcedure

; Compte un echec d'authentification (401) : au-dela du seuil en 60 s,
; /mcp est bloque 30 s (anti brute-force du jeton Bearer).
Procedure HttpNoteAuthFailure()
  If G_HttpAuthMaxFail <= 0 : ProcedureReturn : EndIf
  Protected Now.i = ElapsedMilliseconds()
  If Now - G_HttpAuthWindowStart >= 60000
    G_HttpAuthWindowStart = Now
    G_HttpAuthFailCount = 0
  EndIf
  G_HttpAuthFailCount + 1
  If G_HttpAuthFailCount >= G_HttpAuthMaxFail
    G_HttpAuthLock = Now + 30000
    LogError("Trop d'echecs d'authentification (" + Str(G_HttpAuthMaxFail) + " en 60 s) : /mcp bloque 30 s.")
  EndIf
EndProcedure

Procedure.i HttpTokenAllowed(AuthHeader.s)
  If G_HttpToken = "" : ProcedureReturn #True : EndIf
  Protected A.s = Trim(AuthHeader)
  If Len(A) < 8 : ProcedureReturn #False : EndIf
  If LCase(Left(A, 7)) <> "bearer " : ProcedureReturn #False : EndIf
  ProcedureReturn HttpConstCompare(Mid(A, 8), G_HttpToken)
EndProcedure
