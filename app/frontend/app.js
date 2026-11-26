// Pas de domaine en dur : on appelle /api, et Nginx relaie vers le backend
// (voir nginx.conf.template). C'est ce qui rend le conteneur portable :
// la meme image tourne sur n'importe quelle infra SysOps.

const list = document.getElementById("list");
const form = document.getElementById("form");
const titleInput = document.getElementById("title");
const errorBox = document.getElementById("error");
const versionBadge = document.getElementById("version");
const statsBox = document.getElementById("stats");

function showError(message) {
  errorBox.textContent = message;
  errorBox.hidden = false;
}

function clearError() {
  errorBox.hidden = true;
}

async function loadVersion() {
  try {
    const res = await fetch("/api/version");
    const data = await res.json();
    versionBadge.textContent = "backend " + data.version;
  } catch {
    versionBadge.textContent = "backend injoignable";
  }
}

async function loadStats() {
  try {
    const res = await fetch("/api/stats");
    if (!res.ok) throw new Error("HTTP " + res.status);
    render_stats(await res.json());
  } catch {
    statsBox.innerHTML = "";
  }
}

function render_stats(s) {
  const tiles = [
    ["Total", s.total],
    ["Faites", s.done],
    ["En cours", s.pending],
    ["Avancement", s.completion_rate + " %"],
  ].map(([label, value]) =>
    `<div class="tile"><span class="tile-value">${value}</span>` +
    `<span class="tile-label">${label}</span></div>`
  ).join("");

  const max = Math.max(...s.by_category.map((c) => c.total), 1);
  const bars = s.by_category.map((c) => {
    const pct = Math.round((c.done / c.total) * 100);
    return `<div class="bar-row">
      <span class="bar-label">${c.category}</span>
      <span class="bar-track">
        <span class="bar-fill" style="width:${(c.total / max) * 100}%"></span>
        <span class="bar-done" style="width:${(c.done / max) * 100}%"></span>
      </span>
      <span class="bar-value">${c.done}/${c.total} &middot; ${pct}%</span>
    </div>`;
  }).join("");

  statsBox.innerHTML = `<div class="tiles">${tiles}</div><div class="bars">${bars}</div>`;
}

async function loadTasks() {
  try {
    const res = await fetch("/api/tasks");
    if (!res.ok) throw new Error("HTTP " + res.status);
    const tasks = await res.json();
    clearError();
    render(tasks);
  } catch (err) {
    showError("Impossible de charger les taches : " + err.message);
  }
}

function render(tasks) {
  list.innerHTML = "";
  for (const task of tasks) {
    const li = document.createElement("li");

    const span = document.createElement("span");
    span.textContent = task.title;
    if (task.done) span.classList.add("done");

    const btn = document.createElement("button");
    btn.textContent = "Supprimer";
    btn.className = "delete";
    btn.addEventListener("click", () => deleteTask(task.id));

    li.append(span, btn);
    list.append(li);
  }
}

async function deleteTask(id) {
  try {
    const res = await fetch("/api/tasks/" + id, { method: "DELETE" });
    if (!res.ok) throw new Error("HTTP " + res.status);
    await Promise.all([loadTasks(), loadStats()]);
  } catch (err) {
    showError("Suppression impossible : " + err.message);
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const title = titleInput.value.trim();
  if (!title) return;
  try {
    const res = await fetch("/api/tasks", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title }),
    });
    if (!res.ok) throw new Error("HTTP " + res.status);
    titleInput.value = "";
    await Promise.all([loadTasks(), loadStats()]);
  } catch (err) {
    showError("Ajout impossible : " + err.message);
  }
});

// Rafraichit la version toutes les 2 s : pendant le rolling update, le badge
// change sous les yeux du jury sans aucune interruption de service.
loadVersion();
loadStats();
loadTasks();
setInterval(loadVersion, 2000);
