// Faux client Supabase pour tester l'interface URS Mali sans toucher à la vraie base.
(function () {
  const F = window.__FIX, calls = (window.__CALLS = []);
  const clone = x => JSON.parse(JSON.stringify(x));
  function builder(table) {
    let rows = clone(F[table] || []), single = false, maybe = false;
    const b = {
      select() { return b; }, order() { return b; }, limit() { return b; }, range() { return b; },
      eq(k, v) { rows = rows.filter(r => r[k] === v); return b; },
      maybeSingle() { maybe = true; return b; }, single() { single = true; return b; },
      insert(x) { calls.push(["insert", table, x]); return b; }, upsert(x) { calls.push(["upsert", table, x]); return b; },
      delete() { calls.push(["delete", table]); return b; },
      then(res, rej) { const data = single || maybe ? (rows[0] || null) : rows; return Promise.resolve({ data, error: null }).then(res, rej); },
    };
    return b;
  }
  const now = () => new Date().toISOString();
  const RPC = {
    prowin_code: () => window.__SESSION.user.id === "u-pdg" ? "code-test-0123456789abcdef" : { error: { message: "Réservé au PDG" } },
    soldes: () => [], catalogue: () => [], tarif_livraison: () => 1000, notifs_lues: () => null,
    closing_action: a => {
      const c = F.commandes.find(x => x.id === a.p_id); const me = window.__SESSION.user.id;
      if (!c) return { error: { message: "Commande introuvable" } };
      if (a.p_action === "prendre") Object.assign(c, { vendeur_id: me, closing: "en_cours", closing_le: now() });
      else if (a.p_action === "valider") Object.assign(c, { statut: "nouvelle", closing: "validee", closing_le: now() });
      else if (a.p_action === "relancer") Object.assign(c, { closing: "a_relancer", relance_le: a.p_relance, closing_le: now() });
      else if (a.p_action === "rejeter") Object.assign(c, { closing: "rejetee", vendeur_id: null, rejets: (c.rejets || []).concat([{ par: me, nom: "Awa Vendeuse", le: now(), motif: a.p_texte }]) });
      else if (a.p_action === "annuler") { if (!a.p_texte) return { error: { message: "Indique pourquoi le client ne veut pas la commande" } }; Object.assign(c, { statut: "annulee", closing: "annulee", motif: a.p_texte }); }
      c.maj_le = now(); return null;
    },
  };
  window.supabase = {
    createClient() {
      return {
        auth: {
          getSession: async () => ({ data: { session: window.__SESSION } }),
          onAuthStateChange() { return { data: { subscription: { unsubscribe() {} } } }; },
          signOut: async () => ({ error: null }),
        },
        from: t => builder(t),
        rpc: async (name, args) => {
          calls.push(["rpc", name, args || null]);
          const h = RPC[name]; if (!h) return { data: null, error: null };
          const r = h(args || {}); if (r && r.error) return { data: null, error: r.error };
          return { data: r, error: null };
        },
        channel() { const ch = { on() { return ch; }, subscribe(cb) { if (cb) setTimeout(() => cb("SUBSCRIBED"), 0); return ch; } }; return ch; },
        removeChannel() {},
      };
    },
  };
})();
