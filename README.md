# URS Mali — gestion stock et caisse

Application web d'URS Store Mali : stock, clôtures du jour, trésorerie, engagements, consignes, rapports.
Espace PDG et espace coordonnateur. Comptes : numéro de téléphone + mot de passe.

- Site statique publié par GitHub Pages (fichier `CNAME` : sous-domaine).
- Données et comptes : Supabase (adresse et clé publique dans `config.js` ; les règles d'accès protègent les données).

## Closing des commandes en ligne (PROWIN STORES)

Les commandes de la boutique en ligne PROWIN STORES arrivent dans l'onglet **Closing** des vendeurs :

| Onglet | Signification |
|---|---|
| Disponibles | Nouvelles commandes, visibles par tous les vendeurs ; le premier qui touche « Prendre » l'a |
| En cours | Prises, pas encore closées ; sans suite après 30 min (réglage `closingMinutes`), elles redeviennent disponibles |
| À relancer | Le vendeur doit rappeler le client (heure de rappel) ; la commande reste à lui |
| Validées | Le client a confirmé : la vente part chez les livreurs, commission en attente puis acquise à la livraison |
| Rejetées | Lâchées par un vendeur : tout le monde voit qui et pourquoi, et peut la reprendre |
| Annulées | Le client ne veut pas : terminé |

- Base : `sql/closing-prowin.sql` (à exécuter dans l'éditeur SQL de Supabase, relançable). Il crée une fois pour toutes le code secret `prowin_secret` (table `secrets`).
- Le PDG le copie dans l'application (Closing en ligne → « Code de connexion PROWIN STORES ») et le colle dans PROWIN STORES → Paramètres → « Closing URS Mali ».
- PROWIN STORES appelle `prowin_commande` (entrée des commandes) et `prowin_statuts` (retour des statuts), protégées par ce code secret.
- Tests : `sql/tests/` (base locale qui reproduit URS Mali, et interface avec un faux client Supabase).
