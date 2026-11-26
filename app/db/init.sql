-- Schema + jeu de donnees.
--
-- Rejoue a chaque deploiement : ce script DOIT etre idempotent.
-- Piege : un `INSERT ... ON CONFLICT DO NOTHING` ne protege de rien ici, car
-- l'id est un SERIAL -- aucun conflit a detecter, et chaque execution
-- ajouterait les lignes une fois de plus. D'ou le `WHERE NOT EXISTS`.

CREATE TABLE IF NOT EXISTS tasks (
    id         SERIAL PRIMARY KEY,
    title      TEXT NOT NULL CHECK (length(title) > 0),
    done       BOOLEAN NOT NULL DEFAULT FALSE,
    priority   INTEGER NOT NULL DEFAULT 2 CHECK (priority BETWEEN 1 AND 3),
    category   TEXT NOT NULL DEFAULT 'general',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index sur les colonnes filtrees/agregees : sans lui, /api/stats fait un
-- parcours complet de la table a chaque appel.
CREATE INDEX IF NOT EXISTS idx_tasks_category ON tasks (category);
CREATE INDEX IF NOT EXISTS idx_tasks_done     ON tasks (done);

-- Jeu de donnees genere : 240 lignes reparties sur 6 categories et 90 jours.
-- Assez volumineux pour que les agregations aient du sens et que les
-- graphiques ne soient pas vides pendant la demonstration.
INSERT INTO tasks (title, done, priority, category, created_at)
SELECT
    cat.name || ' #' || g.n,
    (g.n % 3 = 0),
    1 + (g.n % 3),
    cat.name,
    now() - ((g.n % 90) || ' days')::interval
FROM generate_series(1, 40) AS g(n)
CROSS JOIN (VALUES
    ('infrastructure'), ('pipeline'), ('application'),
    ('documentation'), ('tests'), ('monitoring')
) AS cat(name)
WHERE NOT EXISTS (SELECT 1 FROM tasks);
