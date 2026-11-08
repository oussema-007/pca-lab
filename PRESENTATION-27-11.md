# Présentation publique du 27/11 — 5 minutes

**Sujet :** les avantages d'un load balancer dans toute la chaîne de service d'une plateforme d'hébergement couverte par un
SMCA (ISO 22301) — exemple et démo sur l'ERP open source Odoo.

**Public :** classe + jury, pas forcément technique. **Fil rouge :** « Un ERP qui tombe, c'est l'entreprise qui s'arrête ;
le load balancer transforme des pannes et des maintenances en non-événements, et le prouve avec des chiffres. »

Règle : **1 message par slide, 1 chiffre fort par slide.** ≈ 650 mots parlés au total (≈ 130 mots/min).
Tous les chiffres viennent de `RESULTS.md` (mesurés, pas estimés).

---

## Minutage

| # | Slide | Durée | Cumul |
|---|-------|-------|-------|
| 1 | Le problème : l'ERP est une activité critique | 0:30 | 0:30 |
| 2 | La solution : un point d'entrée intelligent | 0:40 | 1:10 |
| 3 | Disponibilité : une panne invisible | 0:50 | 2:00 |
| 4 | Maintenance sans coupure + sécurité en bordure | 0:50 | 2:50 |
| 5 | Scalabilité : un résultat honnête | 0:40 | 3:30 |
| 6 | Lien avec le SMCA : RTO, RPO, disponibilité | 0:50 | 4:20 |
| 7 | Limites et conclusion | 0:40 | 5:00 |

Garder 10–15 s de marge : si on prend du retard, raccourcir la slide 5 (une phrase).

---

## Slide 1 — Le problème (0:30)

**À l'écran :** titre + une phrase : *« Odoo arrêté = plus de devis, plus de commandes, plus de factures. »*
Pictogramme : un serveur unique avec une croix rouge.

**À dire :**
> Dans une entreprise, l'ERP est une activité critique : s'il s'arrête, les commerciaux ne vendent plus.
> La norme ISO 22301 demande de fixer des objectifs : combien de temps on peut être coupé — le RTO —
> et combien de données on peut perdre — le RPO. Avec un seul serveur, chaque panne et chaque mise à jour
> est une coupure. Notre question : qu'apporte un load balancer, et peut-on le mesurer ?

---

## Slide 2 — L'architecture (0:40)

**À l'écran :** le schéma simplifié du README (3 boîtes) :
`Utilisateurs → HAProxy (HTTPS, contrôle) → 3 nœuds Odoo → PostgreSQL (+ réplique)`.
En petit : RHEL 9 durci, SELinux, Docker, pare-feu.

**À dire :**
> On a construit une maquette réelle : trois VM. Les utilisateurs n'entrent que par un seul point, HAProxy,
> qui chiffre la connexion, filtre, et répartit vers trois copies identiques d'Odoo. Elles partagent la même base
> et les mêmes fichiers : n'importe quel nœud peut servir n'importe quel utilisateur.
> Les serveurs Odoo ne sont joignables que par le load balancer.

---

## Slide 3 — Disponibilité : une panne invisible (0:50)

**À l'écran :** chiffre géant **0 erreur** + sous-titre *« nœud détruit en pleine charge »*.
Trois petits chiffres : *détection ≈ 3–4 s · plus longue attente utilisateur ≈ 1,3 s · session conservée*.
Option : capture du terminal vert de `demo_watch.sh` au moment de la bascule.

**À dire :**
> Premier test : pendant que des utilisateurs travaillent, on tue brutalement un des trois serveurs.
> HAProxy vérifie la santé des nœuds toutes les deux secondes : il détecte la panne en 3 à 4 secondes.
> Mais l'utilisateur n'attend même pas ça : les requêtes qui échouent sont rejouées automatiquement sur un autre nœud.
> Résultat mesuré : zéro erreur, au pire 1,3 seconde d'attente, et personne n'a dû se reconnecter.

---

## Slide 4 — Maintenance sans coupure et sécurité (0:50)

**À l'écran :** deux colonnes.
- Gauche : **0 requête perdue** — *« 3 serveurs mis à jour un par un, sous charge »* (drain → maintenance → retour).
- Droite : **500 / 600 bloquées** — *« attaque en rafale : seules 100 requêtes atteignent l'ERP »* + cadenas (HTTPS, en-têtes de sécurité).

**À dire :**
> Deuxième bénéfice : la maintenance. On retire un serveur en douceur — il finit ses requêtes en cours —
> on le met à jour, on le remet. Trois serveurs mis à jour, sous charge : zéro requête perdue.
> C'est exactement la « gestion du changement sans interruption » demandée par le SMCA.
> Troisième bénéfice : la sécurité en bordure. Un script qui martèle la page de connexion est limité :
> sur 600 requêtes, 500 sont refusées par HAProxy avant même d'atteindre Odoo, et un utilisateur normal
> se connecte juste après sans problème.

---

## Slide 5 — Scalabilité : un résultat honnête (0:40)

**À l'écran :** deux barres simples.
- *Même machine, 2 processeurs :* 1 nœud ≈ 3 nœuds (pas de gain, CPU déjà à 93 %).
- *Nœuds indépendants :* 1 nœud **s'effondre (94 % d'erreurs)**, 3 nœuds **0 erreur**.

**À dire :**
> On a aussi mesuré la montée en charge, et on vous donne le résultat honnête : sur une seule machine à deux
> processeurs, ajouter des copies n'ajoute pas de puissance, le processeur est déjà saturé.
> Mais quand chaque nœud a sa propre capacité, un seul nœud s'effondre sous la charge alors que trois la tiennent
> sans aucune erreur. Le load balancer rend l'ajout d'un serveur trivial : une ligne de configuration, sans coupure.

---

## Slide 6 — Le lien avec le SMCA (0:50)

**À l'écran :** tableau 3 lignes.

| Objectif ISO 22301 | Cible | Mesuré |
|--------------------|-------|--------|
| RTO après perte d'un nœud | ≤ 30 s | ≈ 1,3 s ressenti, 0 erreur |
| Coupure en maintenance planifiée | 0 | 0 |
| RPO de la base (réplique) | ≤ 1 s | lag ≈ 1 ms, 0 donnée perdue au crash |

En bas : *« Observabilité : chaque incident est visible et mesuré (stats, logs, Grafana) »* — petite capture du dashboard.

**À dire :**
> Ramené au SMCA : l'objectif de reprise était de 30 secondes, on mesure environ une seconde côté utilisateur.
> La maintenance planifiée ne coûte plus aucune minute de disponibilité. Et pour les données, une réplique de la base
> suit le serveur principal avec une milliseconde de retard : au crash du serveur principal, aucune donnée validée
> n'a été perdue. Surtout, tout est mesuré et rejouable : c'est un exercice de continuité, pas une promesse.

---

## Slide 7 — Limites et conclusion (0:40)

**À l'écran :** trois points de défaillance restants, chacun avec sa réponse en production :
- 1 seul load balancer → **paire keepalived** (adresse IP flottante)
- 1 seule machine pour Odoo → **nœuds sur plusieurs hôtes**
- Bascule de la base manuelle → **Patroni** (bascule automatique)

Phrase finale en gros : *« Le load balancer transforme pannes et maintenances en non-événements — et le prouve. »*

**À dire :**
> Soyons honnêtes sur les limites : dans la maquette, le load balancer lui-même, la machine Odoo et la bascule de la base
> restent des points uniques. En production, on doublerait le load balancer avec keepalived, on répartirait les nœuds
> sur plusieurs hôtes et on automatiserait la base avec Patroni.
> Notre conclusion : le load balancer est le maillon qui transforme les pannes et les maintenances en non-événements
> pour l'utilisateur — et qui permet de le prouver avec des chiffres. Merci.

---

## Préparation pratique

- **Slides :** 7 au maximum, peu de texte, chiffres en très gros. Images à réutiliser : schéma du README,
  `evidence/phase6/grafana-dashboard.png`, `evidence/phase4/browser-sales-orders.png`, une capture du terminal vert de `demo_watch.sh`.
- **Pas de démo live le 27/11** (5 min, trop risqué) : la démo complète a lieu le 20/11. Option si on a la machine :
  une vidéo de 15 s de la bascule (terminal vert + stats qui passe au rouge) en fond de la slide 3.
- **Répéter deux fois avec un chronomètre**, à voix haute. Si on dépasse : couper la phrase « Les serveurs Odoo ne sont
  joignables que par le load balancer » (slide 2) et réduire la slide 5 à sa dernière phrase.
- **Questions probables après la présentation :** voir `DEFENSE-NOTES.md` (Q1 round-robin, Q3 détection/RTO, Q10 scalabilité,
  Q12 points uniques de défaillance).
- **Mots à éviter devant un public non technique :** stick-table, redispatch, runtime API, MCS. Dire plutôt « limite de débit »,
  « rejoue la requête ailleurs », « commandes à chaud », « isolation ».
