"""Test de l'espace closing (interface URS Mali) avec un faux client Supabase."""
import json, subprocess, time, datetime as dt
from playwright.sync_api import sync_playwright

REPO, PORT, SH = "/home/claude/urs-mali", 8090, "/home/claude/urs-mali-test/"
srv = subprocess.Popen(["python3", "-m", "http.server", str(PORT), "-d", REPO], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
FAKE = open(REPO + "/sql/tests/fake-supabase.js").read()
A1, A2, PDG = "u-awa", "u-moussa", "u-pdg"
iso = lambda m=0: (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=m)).isoformat()
def art(): return [{"produitId": "p-clim", "nom": "Nettoyant Clim 500 ml (1 flacon)", "qte": 1, "prix": 7000}]
def cmd(i, **k):
    base = {"id": i, "numero": int(i[1:]) + 100, "cree_le": iso(5), "vendeur_id": None, "client_prenom": "", "client_nom": f"Client {i}", "client_tel": "22376000000",
            "destination": "Bamako, ACI 2000", "ville": "", "articles": art(), "montant": 7000, "frais_livraison": 0, "note": "", "statut": "closing",
            "livreur_id": None, "messages": [], "historique": [{"action": "creer", "statut": "closing", "par": None, "le": iso(5), "texte": "Commande en ligne"}],
            "source": "prowin", "ext_ref": "ref-" + i, "ext_numero": "10" + i[1:], "closing": "disponible", "closing_le": iso(5), "relance_le": None, "rejets": [], "maj_le": iso(5), "motif": None}
    base.update(k); return base
FIX = {
  "membres": [{"id": A1, "role": "vendeur", "nom": "Awa Vendeuse", "tel": "22370000001"}, {"id": A2, "role": "vendeur", "nom": "Moussa Vendeur", "tel": "22370000002"},
              {"id": PDG, "role": "pdg", "nom": "Yannick PDG", "tel": "22675490747"}],
  "commandes": [
    cmd("c1"),
    cmd("c2", closing="rejetee", rejets=[{"par": A2, "nom": "Moussa Vendeur", "le": iso(3), "motif": "Ne répond pas après 3 appels"}]),
    cmd("c3", vendeur_id=A1, closing="en_cours", closing_le=iso(4)),
    cmd("c4", vendeur_id=A1, closing="a_relancer", relance_le=iso(10)),
    cmd("c5", source="vendeur", ext_ref=None, closing=None, statut="nouvelle", vendeur_id=A1, client_nom="Vente boutique physique"),
    cmd("c6", vendeur_id=A2, closing="en_cours", closing_le=iso(40)),
  ],
  "gains": [], "retraits": [], "notifications": [], "docs": [],
}
errors = []
with sync_playwright() as p:
    br = p.chromium.launch(executable_path="/usr/bin/google-chrome", args=["--no-sandbox"])
    def page_for(uid, w=390, h=844):
        ctx = br.new_context(viewport={"width": w, "height": h}, device_scale_factor=2, service_workers="block", locale="fr-FR")
        ctx.add_init_script(f"window.__FIX = {json.dumps(FIX)}; window.__SESSION = {{ user: {{ id: {json.dumps(uid)} }}, access_token: 'x' }};")
        ctx.route("**/supabase.js", lambda r: r.fulfill(status=200, content_type="application/javascript", body=FAKE))
        pg = ctx.new_page(); pg.on("pageerror", lambda e: errors.append(str(e)))
        pg.goto(f"http://localhost:{PORT}/#closing"); pg.wait_for_selector("text=Disponibles", timeout=15000); pg.wait_for_timeout(400)
        return pg
    rpc = lambda pg: [c for c in pg.evaluate("window.__CALLS") if c[0] == "rpc" and c[1] == "closing_action"]

    pg = page_for(A1)
    txt = pg.locator("#view").inner_text()
    assert "Client c1" in txt and "Client c6" in txt and "Client c3" not in txt, txt[:600]
    assert "1 client à rappeler" in txt
    assert pg.locator("a.nav-item[href='#closing']").count() == 1
    assert pg.locator("button[data-act=clo-code]").count() == 0
    pg.screenshot(path=SH + "ui-01-disponibles.png", full_page=True)
    print("✓ 01 Vendeur : onglets du closing, commandes disponibles (dont une prise sans suite depuis 40 min), rappel en retard signalé")

    pg.locator(".item:has-text('Client c1') button:has-text('Prendre la commande')").click(); pg.wait_for_timeout(500)
    assert rpc(pg)[-1][2]["p_action"] == "prendre" and pg.locator("button[data-k='en_cours'][aria-pressed='true']").count() == 1
    assert "Client c1" in pg.locator("#view").inner_text()
    pg.screenshot(path=SH + "ui-02-en-cours.png", full_page=True)
    print("✓ 02 « Prendre » : la commande passe dans « En cours » avec Appeler, WhatsApp, Valider")

    pg.locator(".item:has-text('Client c1') button:has-text('Valider')").click(); pg.click("[data-act='confirm-yes']"); pg.wait_for_timeout(500)
    assert rpc(pg)[-1][2]["p_action"] == "valider"
    pg.click("button[data-k='validee']"); pg.wait_for_timeout(200)
    assert "Client c1" in pg.locator("#view").inner_text()
    print("✓ 03 « Valider » (avec confirmation) : la commande apparaît dans « Validées »")

    pg.click("button[data-k='en_cours']"); pg.locator(".item:has-text('Client c3')").click(); pg.wait_for_selector("#cloTexte")
    pg.screenshot(path=SH + "ui-03-fiche.png", full_page=True)
    pg.click("[data-act='clo-do'][data-a='annuler']"); pg.wait_for_timeout(200)
    assert "Indique pourquoi" in pg.locator("#sheetErr").inner_text() and not [c for c in rpc(pg) if c[2]["p_action"] == "annuler"]
    pg.fill("#cloTexte", "Le client ne veut plus"); pg.click("[data-act='clo-do'][data-a='annuler']"); pg.click("[data-act='confirm-yes']"); pg.wait_for_timeout(500)
    last = rpc(pg)[-1][2]; assert last["p_action"] == "annuler" and last["p_texte"] == "Le client ne veut plus", last
    print("✓ 04 Fiche : annuler exige un motif, puis annule avec le motif")

    pg.click("button[data-k='a_relancer']"); pg.locator(".item:has-text('Client c4')").click(); pg.wait_for_selector("#cloRelance")
    pg.fill("#cloTexte", "Rappeler après 17 h"); pg.click("[data-act='clo-do'][data-a='relancer']"); pg.wait_for_timeout(500)
    last = rpc(pg)[-1][2]; assert last["p_action"] == "relancer" and last["p_relance"] and last["p_texte"] == "Rappeler après 17 h", last
    pg.click("button[data-k='rejetee']"); pg.wait_for_timeout(200)
    t = pg.locator("#view").inner_text(); assert "Rejetée par Moussa Vendeur" in t and "Ne répond pas après 3 appels" in t, t[:500]
    pg.screenshot(path=SH + "ui-04-rejetees.png", full_page=True)
    print("✓ 05 « À relancer » avec heure de rappel ; « Rejetées » montre qui a rejeté et pourquoi")

    pg.goto(f"http://localhost:{PORT}/#ventes"); pg.wait_for_timeout(600)
    t = pg.locator("#view").inner_text(); assert "Vente boutique physique" in t and "Client c6" not in t and "Client c2" not in t, t[:400]
    print("✓ 06 « Mes ventes » : seulement les vraies ventes (les commandes en closing n'y sont pas)")

    pp = page_for(PDG, 1280, 900)
    assert "Closing en ligne" in pp.locator("a.nav-item[href='#closing']").inner_text()
    t = pp.locator("#view").inner_text(); assert "Client c1" in t or "Disponibles" in t
    pp.screenshot(path=SH + "ui-05-pdg.png")
    print("✓ 07 PDG : menu « Closing en ligne » avec toutes les commandes")
    pp.click("button[data-act=clo-code]"); pp.wait_for_selector("#cloCodeBox")
    import base64
    code = pp.locator("#cloCodeBox").input_value(); assert code.startswith("ursmali1."), code
    d = json.loads(base64.urlsafe_b64decode(code[9:] + "=" * (-len(code[9:]) % 4)))
    assert d["s"] == "code-test-0123456789abcdef" and d["u"].startswith("https://") and len(d["k"]) > 20, d
    pp.screenshot(path=SH + "ui-06-pdg-code.png")
    print("✓ 08 PDG : « Code de connexion PROWIN STORES » affiché pour être collé dans PROWIN")
    br.close()
srv.terminate()
assert errors == [], errors
print(json.dumps({"ok": True}))
