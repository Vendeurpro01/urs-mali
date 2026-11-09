"""Tests de la migration closing (base locale qui reproduit URS Mali)."""
import json, subprocess, threading

DB = "ursmali_test"
PDG, A1, A2, L1 = ("00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-0000000000a1",
                   "00000000-0000-0000-0000-0000000000a2", "00000000-0000-0000-0000-0000000000b1")
SECRET = "test-secret-123"
STEP = [0]

def ok(m):
    STEP[0] += 1
    print(f"✓ {STEP[0]:02d} {m}", flush=True)

def run(sql, user=None, role="authenticated"):
    pre = "begin; set local role anon;" if role == "anon" else f"begin; set local role authenticated; set local request.jwt.claim.sub = '{user}';"
    p = subprocess.run(["sudo", "-u", "postgres", "psql", "-At", "-q", "-v", "ON_ERROR_STOP=1", "-d", DB, "-c", pre + sql + "; commit;"],
                       capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError(p.stderr.strip())
    return p.stdout.strip()

def admin(sql):
    return subprocess.check_output(["sudo", "-u", "postgres", "psql", "-At", "-q", "-d", DB, "-c", sql], text=True).strip()

def err(sql, user=None, role="authenticated"):
    try:
        run(sql, user, role)
    except RuntimeError as e:
        return str(e)
    raise AssertionError("aurait dû échouer : " + sql)

def cmd(ref, phone="22670112233", qty=1):
    payload = {"ref": ref, "number": "10" + ref[-2:], "customerName": "Client Test", "phone": phone, "address": "Ouaga, Tampouy",
               "city": None, "deliveryFee": 0, "note": "",
               "items": [{"productId": "prw-1", "title": "Nettoyant Clim (mousse nettoyante pour climatisation) 500 ml", "variant": "1 flacon", "quantity": qty, "unitPrice": 7000}]}
    return json.dumps(payload).replace("'", "''")

admin("delete from notifications; delete from gains; delete from commandes")

# 1-3. Entrée des commandes
assert "Accès refusé" in err(f"select prowin_commande('mauvais', '{cmd('r-01')}')", role="anon")
r = json.loads(run(f"select prowin_commande('{SECRET}', '{cmd('r-01')}')", role="anon"))
row = admin(f"select statut, closing, coalesce(vendeur_id::text,'null'), source, montant, articles->0->>'produitId' from commandes where ext_ref='r-01'").split("|")
assert row == ["closing", "disponible", "null", "prowin", "7000", "p-clim"], row
r2 = json.loads(run(f"select prowin_commande('{SECRET}', '{cmd('r-01')}')", role="anon"))
assert r2["deja"] and r2["numero"] == r["numero"]
ok("PROWIN → URS Mali : code secret obligatoire, commande en closing « disponible », produit reconnu par son nom, renvoi sans doublon")

# 4-5. Notifications et visibilité
n = admin(f"select string_agg(membre_id::text||':'||type, ',' order by membre_id) from notifications where commande_id='{r['id']}'")
assert f"{A1}:closing" in n and f"{A2}:closing" in n and f"{PDG}:vente" in n and L1 not in n, n
assert run(f"select count(*) from commandes where ext_ref='r-01'", A2) == "1"
assert run(f"select count(*) from commandes where ext_ref='r-01'", L1) == "0"
ok("Tous les vendeurs sont notifiés et voient la commande ; les livreurs ne la voient pas encore")

# 6. Un vendeur ne peut pas fabriquer une commande « en ligne »
run(f"insert into commandes (client_nom, client_tel, destination, articles, source, statut, closing, ext_ref) values ('X','22370000009','Bamako','[{{\"nom\":\"P\",\"qte\":1,\"prix\":10}}]','prowin','closing','disponible','faux')", A1)
assert admin("select source||'|'||statut||'|'||coalesce(ext_ref,'null') from commandes where client_nom='X'") == "vendeur|nouvelle|null"
ok("Une vente saisie par un vendeur reste une vente normale (impossible de se faire passer pour PROWIN)")

# 7. Le premier qui prend l'a
run(f"select closing_action('{r['id']}', 'prendre')", A1)
e = err(f"select closing_action('{r['id']}', 'prendre')", A2)
assert "Déjà prise par Awa Vendeuse" in e, e
assert run(f"select count(*) from commandes where ext_ref='r-01'", A2) == "0"
ok("Awa prend la commande ; Moussa ne peut plus la prendre et ne la voit plus")

# 8. Deux vendeurs à la même seconde : un seul gagne
r3 = json.loads(run(f"select prowin_commande('{SECRET}', '{cmd('r-03')}')", role="anon"))
res = {}
def take(u):
    try: run(f"select pg_sleep(0.2); select closing_action('{r3['id']}', 'prendre')", u); res[u] = "ok"
    except RuntimeError as ex: res[u] = str(ex)
ts = [threading.Thread(target=take, args=(u,)) for u in (A1, A2)]
[t.start() for t in ts]; [t.join() for t in ts]
assert sorted(v == "ok" for v in res.values()) == [False, True], res
ok("Deux vendeurs appuient en même temps : un seul obtient la commande")

# 9-10. À relancer, puis rejet : visible et reprenable par tous
run(f"select closing_action('{r['id']}', 'relancer', 'Client en réunion, rappeler à 15 h', now() + interval '2 hours')", A1)
assert admin(f"select closing||'|'||(relance_le > now() + interval '1 hour') from commandes where id='{r['id']}'") == "a_relancer|true"
run(f"select closing_action('{r['id']}', 'rejeter', 'Ne répond pas après 3 appels')", A1)
row = admin(f"select closing, coalesce(vendeur_id::text,'null'), rejets->0->>'nom', rejets->0->>'motif' from commandes where id='{r['id']}'").split("|")
assert row == ["rejetee", "null", "Awa Vendeuse", "Ne répond pas après 3 appels"], row
assert admin(f"select count(*) from notifications where commande_id='{r['id']}' and membre_id='{A2}' and titre like '%rejetée%'") == "1"
assert run(f"select count(*) from commandes where id='{r['id']}'", A2) == "1"
run(f"select closing_action('{r['id']}', 'prendre')", A2)
ok("À relancer (heure de rappel), puis rejetée : Moussa est notifié, la voit avec le motif d'Awa et la reprend")

# 11. Validation : livreurs, commission, livraison
run(f"select closing_action('{r['id']}', 'valider')", A2)
row = admin(f"select statut, closing, vendeur_id from commandes where id='{r['id']}'").split("|")
assert row == ["nouvelle", "validee", A2], row
assert admin(f"select montant||'|'||statut from gains where commande_id='{r['id']}' and type='commission' and membre_id='{A2}'") == "1000|attente"
assert admin(f"select count(*) from notifications where commande_id='{r['id']}' and membre_id='{L1}' and titre like 'Nouvelle course%'") == "1"
assert run(f"select count(*) from commandes where id='{r['id']}'", L1) == "1"
run(f"select commande_action('{r['id']}', 'prendre')", L1); run(f"select commande_action('{r['id']}', 'livree')", L1)
assert admin(f"select statut from gains where commande_id='{r['id']}' and type='commission'") == "acquis"
assert "n'est plus en closing" in err(f"select closing_action('{r['id']}', 'annuler', 'x')", A2)
ok("Validée par Moussa : la course part chez les livreurs, commission 1 000 F en attente puis acquise à la livraison")

# 12. Annulation (motif obligatoire)
r4 = json.loads(run(f"select prowin_commande('{SECRET}', '{cmd('r-04')}')", role="anon"))
run(f"select closing_action('{r4['id']}', 'prendre')", A1)
assert "Indique pourquoi" in err(f"select closing_action('{r4['id']}', 'annuler', '')", A1)
run(f"select closing_action('{r4['id']}', 'annuler', 'Le client ne veut plus')", A1)
assert admin(f"select statut||'|'||closing||'|'||motif from commandes where id='{r4['id']}'") == "annulee|annulee|Le client ne veut plus"
ok("Annulée avec motif obligatoire")

# 13. Prise sans suite pendant 30 min : redevient disponible pour les autres
r5 = json.loads(run(f"select prowin_commande('{SECRET}', '{cmd('r-05')}')", role="anon"))
run(f"select closing_action('{r5['id']}', 'prendre')", A1)
assert "Déjà prise" in err(f"select closing_action('{r5['id']}', 'prendre')", A2)
admin(f"update commandes set closing_le = now() - interval '31 minutes' where id='{r5['id']}'")
assert run(f"select count(*) from commandes where id='{r5['id']}'", A2) == "1"
run(f"select closing_action('{r5['id']}', 'prendre')", A2)
assert admin(f"select vendeur_id from commandes where id='{r5['id']}'") == A2
ok("Prise depuis plus de 30 min sans suite : un autre vendeur peut la reprendre")

# 14-16. Droits et retour vers PROWIN
assert "Réservé aux vendeurs" in err(f"select closing_action('{r5['id']}', 'valider')", L1)
vid = admin("select id from commandes where client_nom='X'")
assert "Commande introuvable" in err(f"select closing_action('{vid}', 'prendre')", A1)
assert "Accès refusé" in err("select * from prowin_statuts('mauvais', null)", role="anon")
st = run(f"select string_agg(ref||':'||statut||':'||coalesce(closing,'')||':'||coalesce(vendeur,''), ',' order by ref) from prowin_statuts('{SECRET}', null)", role="anon")
assert "r-01:livree:validee:Moussa Vendeur" in st and "r-04:annulee:annulee:Awa Vendeuse" in st and "r-05:closing:en_cours:Moussa Vendeur" in st, st
ok("Droits : livreur refusé, ventes normales hors closing ; PROWIN récupère statuts et nom du closer (code secret obligatoire)")
# 11. Code de connexion : lisible par le PDG seulement, jamais régénéré
assert run("select prowin_code()", PDG) == SECRET
assert "Réservé au PDG" in err("select prowin_code()", A1) and "Réservé au PDG" in err("select prowin_code()", L1)
assert "permission denied" in err("select prowin_code()", role="anon")
subprocess.run(["sudo", "-u", "postgres", "psql", "-q", "-v", "ON_ERROR_STOP=1", "-d", DB, "-f", "/home/claude/urs-mali/sql/closing-prowin.sql"], capture_output=True, check=True)
assert admin("select valeur from secrets where cle='prowin_secret'") == SECRET
ok("Code de connexion PROWIN : PDG seulement (vendeur, livreur, anonyme refusés) ; relancer la mise à jour ne le change pas")
print(json.dumps({"ok": True, "steps": STEP[0]}))
