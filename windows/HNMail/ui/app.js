// HN Mail pour Windows : interface (la partie réseau, les clés et les notifications sont dans l'app C#).
'use strict';

// ---------- pont avec l'app ----------
const pending = new Map();
let nextId = 1;
function call(cmd, data) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    window.chrome.webview.postMessage({ id, cmd, data: data ?? null });
  });
}
window.chrome.webview.addEventListener('message', (event) => {
  const msg = event.data;
  if (msg.id && pending.has(msg.id)) {
    const p = pending.get(msg.id); pending.delete(msg.id);
    msg.ok ? p.resolve(msg.data) : p.reject(new Error(msg.error));
    return;
  }
  if (msg.event === 'inbox') { setMessages(msg.messages); error = ''; render(); }
  if (msg.event === 'error') { error = msg.message; render(); }
  if (msg.event === 'open') openMessage(msg.id);
  if (msg.event === 'update') { state.update = msg.update; renderUpdate(); }
});

// ---------- modèles ----------
const DEFAULT_TEMPLATES = [
  { id: 'support', name: 'Support logiciel', subtitle: 'Aide + guide', eyebrow: 'Support logiciel', title: 'Réponse à ta demande',
    message: 'Merci pour ton message. Voici ce que tu peux essayer :\n\n', rows: [{ key: 'Ta demande', value: '{objet}' }, { key: 'Guides', value: 'heivoli-network.fr/logiciels.html' }],
    buttonLabel: 'Voir les logiciels et guides', buttonURL: 'https://heivoli-network.fr/logiciels.html', accent: 'brand' },
  { id: 'partenariat', name: 'Partenariat', subtitle: 'Merci / suite', eyebrow: 'Partenariat', title: 'Merci pour ta proposition',
    message: "Merci d'avoir pensé à Heivoli Network ! Nous avons bien reçu ta proposition et nous revenons vers toi très vite.",
    rows: [{ key: 'Proposition', value: '{objet}' }, { key: 'Suite', value: 'Réponse sous quelques jours' }],
    buttonLabel: 'Rejoindre le Discord', buttonURL: 'https://discord.gg/Z7kZ3WWZxw', accent: 'brand' },
  { id: 'donnees', name: 'Données perso', subtitle: 'Suppression RGPD', eyebrow: 'Données personnelles', title: 'Ta demande concernant tes données',
    message: "Nous avons bien reçu ta demande. Ton compte et les données associées seront supprimés sous 30 jours maximum. Tu recevras une confirmation une fois l'opération terminée.",
    rows: [{ key: 'Demande', value: '{objet}' }, { key: 'Délai', value: '30 jours maximum' }],
    buttonLabel: 'Politique de confidentialité', buttonURL: 'https://heivoli-network.fr/conditions.html#confidentialite', accent: 'brand' },
  { id: 'merci', name: 'Remerciement', subtitle: 'Message gentil', eyebrow: 'Merci', title: 'Merci pour ton message !',
    message: "Ton message nous a fait super plaisir, merci ! C'est grâce à des retours comme le tien que la communauté avance.",
    rows: [], buttonLabel: 'Découvrir les nouveautés', buttonURL: 'https://heivoli-network.fr', accent: 'success' },
  { id: 'contestation', name: 'Contestation', subtitle: 'Acceptée / refusée', eyebrow: 'Modération', title: 'Réponse à ta contestation',
    message: 'La modération a examiné ta contestation.\n\nDécision : ', rows: [{ key: 'Concerne', value: '{objet}' }],
    buttonLabel: 'Relire les règles', buttonURL: 'https://heivoli-network.fr/conditions.html#regles', accent: 'warning' },
  { id: 'libre', name: 'Libre', subtitle: 'Sans modèle', eyebrow: 'Heivoli Network', title: 'Réponse à ton message',
    message: '', rows: [], buttonLabel: '', buttonURL: '', accent: 'brand' },
];
const CATEGORIES = { appeal: ['Contestation', 'contestation'], data: ['Données', 'donnees'], partnership: ['Partenariat', 'partenariat'], software: ['Support logiciel', 'support'], thanks: ['Remerciement', 'merci'], other: ['Autre', 'libre'] };
function category(m) {
  const t = `${m.subject} ${m.text}`.toLowerCase();
  const has = (words) => words.some((w) => t.includes(w));
  if (has(['ban', 'banni', 'contest', 'sanction', 'avertissement'])) return CATEGORIES.appeal;
  if (has(['supprimer mon compte', 'suppression', 'mes données', 'rgpd', 'données personnelles', 'effacer'])) return CATEGORIES.data;
  if (has(['partenariat', 'partenaire', 'collaboration', 'sponsor', 'tournoi'])) return CATEGORIES.partnership;
  if (has(['screenlink', 'theme studio', 'thème', 'hn screen', '3dsx', 'cia', 'bug', 'installer', 'marche pas', 'fonctionne pas', 'erreur'])) return CATEGORIES.software;
  if (has(['merci', 'bravo', 'génial', 'trop bien', 'super'])) return CATEGORIES.thanks;
  return CATEGORIES.other;
}

// ---------- rendu du mail (style sobre, identique à l'app Mac) ----------
const FONT = "-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
const SITE = 'https://heivoli-network.fr';
const ACCENTS = { brand: '#5a4bd8', warning: '#d9730d', danger: '#c4271b', success: '#3d8a12' };
const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const fill = (s, first, subject) => String(s ?? '').replaceAll('{prenom}', first).replaceAll('{objet}', subject);
function renderMail(tpl, message, first, subject, buttonLabel) {
  const color = ACCENTS[tpl.accent] || ACCENTS.brand;
  const paragraphs = fill(message, first, subject).split('\n\n').map((p) => p.trim()).filter(Boolean)
    .map((p) => `<p style="margin:0 0 16px;font:15px/1.6 ${FONT};color:#3c3c43">${esc(p).replace(/\n/g, '<br>')}</p>`).join('');
  const rows = (tpl.rows || []).map((r) => ({ key: r.key, value: fill(r.value, first, subject) })).filter((r) => r.key && r.value);
  const table = rows.length ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:4px 0 24px;border-top:2px solid #1c1c1e;border-bottom:1px solid #e5e5ea">${rows.map((r, i) => {
    const b = i ? 'border-top:1px solid #e5e5ea;' : '';
    return `<tr><td style="padding:12px 0;${b}width:120px;vertical-align:top;font:600 13px/1.5 ${FONT};color:#8e8e93">${esc(r.key)}</td><td style="padding:12px 0;${b}vertical-align:top;font:15px/1.5 ${FONT};color:#1c1c1e">${esc(r.value)}</td></tr>`;
  }).join('')}</table>` : '';
  const button = buttonLabel && /^https:\/\//.test(tpl.buttonURL || '') ? `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 20px"><tr><td style="background:${color};border-radius:6px"><a href="${esc(tpl.buttonURL)}" style="display:inline-block;padding:13px 26px;font:600 15px/1 ${FONT};color:#ffffff;text-decoration:none;border-radius:6px">${esc(buttonLabel)}</a></td></tr></table>` : '';
  const greeting = first ? `Bonjour ${esc(first)},` : 'Bonjour,';
  return `<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>${esc(subject)}</title></head>
<body style="margin:0;padding:0;background:#f2f2f7"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f2f2f7"><tr><td align="center" style="padding:28px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff">
<tr><td style="height:6px;background:#5a4bd8;font-size:0;line-height:0">&nbsp;</td></tr>
<tr><td style="padding:22px 36px;border-bottom:1px solid #e5e5ea"><table role="presentation" cellpadding="0" cellspacing="0"><tr>
<td style="vertical-align:middle"><a href="${SITE}"><img src="${SITE}/assets/hn-logo.png" width="40" height="40" alt="" style="display:block;border:0"></a></td>
<td style="vertical-align:middle;padding-left:12px;font:700 16px/1 ${FONT};color:#1c1c1e">Heivoli Network</td></tr></table></td></tr>
<tr><td style="padding:36px 36px 12px">
<p style="margin:0 0 10px;font:700 12px/1 ${FONT};letter-spacing:.08em;text-transform:uppercase;color:${color}">${esc(tpl.eyebrow)}</p>
<h1 style="margin:0 0 22px;font:700 26px/1.25 ${FONT};letter-spacing:-.015em;color:#1c1c1e">${esc(fill(tpl.title, first, subject))}</h1>
<p style="margin:0 0 16px;font:15px/1.6 ${FONT};color:#3c3c43">${greeting}</p>${paragraphs}${table}${button}
<p style="margin:0 0 8px;font:15px/1.6 ${FONT};color:#3c3c43">À bientôt,<br><strong>L'équipe Heivoli Network</strong></p></td></tr>
<tr><td style="padding:24px 36px;background:#f7f7f9;border-top:1px solid #e5e5ea;font:12px/1.7 ${FONT};color:#8e8e93">
<a href="${SITE}" style="color:#3c3c43;text-decoration:none;font-weight:600">Site</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="${SITE}/tickets.html" style="color:#3c3c43;text-decoration:none;font-weight:600">Aide</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="https://discord.gg/Z7kZ3WWZxw" style="color:#3c3c43;text-decoration:none;font-weight:600">Discord</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="${SITE}/conditions.html#confidentialite" style="color:#3c3c43;text-decoration:none;font-weight:600">Confidentialité</a><br><br>
Pour nous répondre, réponds simplement à ce mail.<br>Heivoli Network est un projet communautaire indépendant, non affilié à Nintendo.<br>© ${new Date().getFullYear()} Heivoli Network
</td></tr></table></td></tr></table></body></html>`;
}

// ---------- état ----------
let messages = [];
let replied = {};
let templates = DEFAULT_TEMPLATES.map((t) => structuredClone(t));
let folder = 'todo';
let selectedId = null;
let search = '';
let error = '';
let state = {};
let loading = false;

const $ = (sel) => document.querySelector(sel);
const firstName = (m) => {
  const src = m.fromName || (m.fromEmail || '').split('@')[0] || '';
  const w = src.split(' ')[0] || '';
  return w ? w[0].toUpperCase() + w.slice(1) : '';
};
function setMessages(list) {
  messages = (list || []).map((m) => ({ ...m, fromEmail: (m.replyTo || m.fromEmail || '').toLowerCase(), text: (m.text || '').trim(), dateObj: new Date(m.date || m.receivedAt || Date.now()) }))
    .sort((a, b) => b.dateObj - a.dateObj);
}
const isReplied = (m) => !!m.repliedAt || Object.prototype.hasOwnProperty.call(replied, m.id);
const repliedLabel = (m) => {
  const by = m.repliedBy || state.teamName || '';
  return !by || by === state.teamName ? 'Répondu' : `Répondu par ${by}`;
};
function inFolder(m, f) {
  if (f === 'todo') return m.mailbox !== 'news' && !isReplied(m);
  if (f === 'replied') return isReplied(m);
  if (f === 'all') return m.mailbox !== 'news';
  return m.mailbox === 'news';
}
function visible() {
  const q = search.trim().toLowerCase();
  return messages.filter((m) => inFolder(m, folder)).filter((m) => !q || `${m.fromName} ${m.fromEmail} ${m.subject} ${m.text}`.toLowerCase().includes(q));
}
const template = (id) => templates.find((t) => t.id === id) || templates[templates.length - 1] || DEFAULT_TEMPLATES[5];

// ---------- affichage ----------
function render() {
  document.querySelectorAll('.side a[data-folder]').forEach((a) => a.classList.toggle('on', a.dataset.folder === folder));
  for (const f of ['todo', 'replied', 'all', 'news']) {
    const n = messages.filter((m) => inFolder(m, f) && (f !== 'news' || !isReplied(m))).length;
    $(`[data-count="${f}"]`).textContent = n || '';
  }
  const ready = state.inboxConfigured && state.brevoConfigured;
  $('#status-dot').classList.toggle('ok', !!ready);
  $('#status-text').textContent = state.inboxConfigured ? 'Boîte contact@ connectée' : 'Clé HN Mail manquante';

  const list = $('#list');
  const items = visible();
  if (!items.find((m) => m.id === selectedId)) selectedId = items[0]?.id ?? null;
  if (!items.length) {
    list.innerHTML = `<div class="empty">${loading ? 'Chargement des mails…' : error ? `⚠️<br>${esc(error)}` : folder === 'todo' ? 'Tout est traité ✨' : 'Aucun mail ici'}</div>`;
  } else {
    list.innerHTML = items.map((m) => {
      const cat = category(m)[0];
      const when = m.dateObj.toLocaleString('fr-FR', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
      return `<div class="item${m.id === selectedId ? ' on' : ''}" data-id="${esc(m.id)}"><div class="top"><strong>${esc(m.fromName || m.fromEmail)}</strong><time>${esc(when)}</time></div>
        <span class="sub">${esc(m.subject)}</span><span class="pre">${esc(m.text.slice(0, 220))}</span>
        <span class="tag${isReplied(m) ? ' done' : ''}">${isReplied(m) ? esc(repliedLabel(m)) : esc(cat)}</span></div>`;
    }).join('');
  }
  renderMain();
}

let shownId = null;
function renderMain() {
  const main = $('#main');
  const m = messages.find((x) => x.id === selectedId);
  if (!m) {
    shownId = null;
    const ready = state.inboxConfigured && state.brevoConfigured;
    main.innerHTML = `<div class="empty"><div><div class="big">✉️</div><h2>HN Mail</h2><p>${ready ? 'Choisis un mail à gauche pour y répondre.' : 'Pour commencer, ajoute ta clé HN Mail et ta clé Brevo.'}</p>${ready ? '' : '<button class="primary" id="empty-settings">Ouvrir les Réglages</button>'}</div></div>`;
    $('#empty-settings')?.addEventListener('click', openSettings);
    return;
  }
  if (shownId === m.id) { $('#toggle-replied').textContent = isReplied(m) ? 'Remettre à traiter' : 'Marquer comme traité'; return; }
  shownId = m.id;
  main.innerHTML = `<div class="read"><h2>${esc(m.subject)}</h2>
    <div class="from"><div class="av">${esc(firstName(m).slice(0, 1) || '?')}</div><div class="who"><strong>${esc(m.fromName || m.fromEmail)}</strong><br>${esc(m.fromEmail)} · à ${m.mailbox === 'news' ? 'news' : 'contact'}@heivoli-network.fr</div>
    <button id="toggle-replied">${isReplied(m) ? 'Remettre à traiter' : 'Marquer comme traité'}</button></div>
    <div class="text">${esc(m.text)}</div>
    ${m.attachments?.length ? `<div class="attach">📎 Pièces jointes : ${esc(m.attachments.join(', '))} (visibles dans le Gmail de l'équipe)</div>` : ''}</div>
    <div class="compose-host" id="reply-host"></div>`;
  $('#toggle-replied').addEventListener('click', async () => {
    state = await call('setReplied', { messageId: m.id, value: !isReplied(m) });
    replied = state.replied || {};
    setMessages(state.messages);
    shownId = null;
    render();
  });
  mountComposer($('#reply-host'), {
    email: m.fromEmail, name: m.fromName, first: firstName(m), originalSubject: m.subject,
    subject: /^re:/i.test(m.subject) ? m.subject : `Re: ${m.subject}`, inReplyTo: m.messageId, mailbox: 'contact',
    template: category(m)[1], messageId: m.id, editable: false, body: m.text,
  });
}

let autoCorrectBeforeSend = async () => true;
function mountComposer(host, target) {
  let tplId = '';
  let text = '';
  let buttonLabel = '';
  let phone = false;
  host.innerHTML = `<div class="form">
    ${target.editable ? `<label>Destinataire<input id="c-to" placeholder="adresse@exemple.fr"></label>
      <label>Prénom (pour « Bonjour … »)<input id="c-first" placeholder="Facultatif"></label>
      <label>Envoyer depuis<select id="c-box"><option value="contact">contact@heivoli-network.fr</option><option value="news">news@heivoli-network.fr</option></select></label>` : ''}
    <label>Réponse prête<div class="tpls" id="c-tpls"></div></label>
    <label>Objet<input id="c-subject"></label>
    <label>Ton message<textarea id="c-text" spellcheck="true" lang="fr"></textarea></label>
    <div class="ai">
      <input id="c-ai-hint" placeholder="Consigne pour l'IA (facultatif) : ex. « refuse poliment »">
      <div class="ai-row"><button id="c-ai-draft" title="L'IA lit le mail reçu et écrit une réponse à partir du modèle choisi">✨ Proposer une réponse</button>
      <button id="c-ai-fix" title="Corrige l'orthographe et la grammaire sans changer ton texte">Corriger</button>
      <button id="c-ai-undo" hidden title="Revenir au texte d'avant l'IA">Annuler</button></div>
      <span class="ai-msg" id="c-ai-msg"></span>
    </div>
    <label>Texte du bouton (vide = pas de bouton)<input id="c-button"></label>
    <button class="primary send" id="c-send">Envoyer depuis contact@ ➤</button>
    <span class="msg" id="c-msg"></span>
    <span class="note">Envoyé avec Brevo, dans la même conversation que le mail reçu. Ctrl+Entrée pour envoyer.</span>
  </div>
  <div class="prev"><div class="cap"><span>APERÇU DU MAIL</span><div class="seg"><button class="on" id="c-desk">Ordinateur</button><button id="c-phone">Téléphone</button></div></div><iframe id="c-frame" sandbox="allow-same-origin" title="Aperçu"></iframe></div>`;
  const q = (s) => host.querySelector(s);
  q('#c-subject').value = target.subject;
  const update = () => {
    const tpl = template(tplId);
    q('#c-frame').srcdoc = renderMail(tpl, text, target.first, target.originalSubject, buttonLabel);
    q('#c-send').textContent = `Envoyer depuis ${target.mailbox === 'news' ? 'news@' : 'contact@'} ➤`;
    q('#c-tpls').querySelectorAll('.tpl').forEach((b) => b.classList.toggle('on', b.dataset.id === tplId));
  };
  const apply = (tpl) => { tplId = tpl.id; text = fill(tpl.message, target.first, target.originalSubject); buttonLabel = tpl.buttonLabel; q('#c-text').value = text; q('#c-button').value = buttonLabel; update(); };
  q('#c-tpls').innerHTML = templates.map((t) => `<button class="tpl" data-id="${esc(t.id)}">${esc(t.name)}<small>${esc(t.subtitle)}</small></button>`).join('');
  q('#c-tpls').addEventListener('click', (e) => { const b = e.target.closest('.tpl'); if (b) { e.preventDefault(); apply(template(b.dataset.id)); } });
  q('#c-text').addEventListener('input', (e) => { text = e.target.value; update(); });
  q('#c-button').addEventListener('input', (e) => { buttonLabel = e.target.value; update(); });
  q('#c-subject').addEventListener('input', (e) => { target.subject = e.target.value; if (target.editable) { target.originalSubject = e.target.value; update(); } });
  if (target.editable) {
    q('#c-to').addEventListener('input', (e) => { target.email = e.target.value.trim(); });
    q('#c-first').addEventListener('input', (e) => { target.first = e.target.value.trim(); update(); });
    q('#c-box').addEventListener('change', (e) => { target.mailbox = e.target.value; update(); });
  }
  q('#c-desk').addEventListener('click', () => { phone = false; q('#c-frame').classList.remove('phone'); q('#c-desk').classList.add('on'); q('#c-phone').classList.remove('on'); });
  q('#c-phone').addEventListener('click', () => { phone = true; q('#c-frame').classList.add('phone'); q('#c-phone').classList.add('on'); q('#c-desk').classList.remove('on'); });
  const send = async () => {
    const msg = q('#c-msg');
    const email = (target.email || '').trim();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { msg.className = 'msg err'; msg.textContent = 'Adresse du destinataire invalide.'; return; }
    if (!target.subject.trim()) { msg.className = 'msg err'; msg.textContent = 'Ajoute un objet.'; return; }
    const button = q('#c-send');
    button.disabled = true; button.textContent = 'Vérification…'; msg.textContent = '';
    if (!(await autoCorrectBeforeSend())) { button.disabled = false; update(); return; }
    button.textContent = 'Envoi…';
    try {
      state = await call('send', {
        mailbox: target.mailbox, toEmail: email, toName: target.name || '', subject: target.subject,
        html: renderMail(template(tplId), text, target.first, target.originalSubject, buttonLabel),
        inReplyTo: target.inReplyTo || '', messageId: target.messageId || '',
      });
      replied = state.replied || replied;
      if (target.messageId) setMessages(state.messages);
      msg.className = 'msg ok'; msg.textContent = `Envoyé à ${email} ✓`;
      render();
    } catch (e) {
      msg.className = 'msg err'; msg.textContent = e.message;
    }
    button.disabled = false; update();
  };
  q('#c-send').addEventListener('click', send);

  // ----- IA -----
  let before = null;
  let correctedFor = '';
  const setText = (value) => { before = text; text = value; q('#c-text').value = value; q('#c-ai-undo').hidden = false; update(); };
  const aiMsg = (value, err) => { const el = q('#c-ai-msg'); el.textContent = value; el.className = `ai-msg${err ? ' err' : ''}`; };
  const busy = (on) => { ['#c-ai-draft', '#c-ai-fix', '#c-send'].forEach((s) => { q(s).disabled = on; }); };
  q('#c-ai-draft').addEventListener('click', async () => {
    busy(true); aiMsg("L'IA écrit…");
    try {
      const tpl = template(tplId);
      const result = await call('ai', { action: 'draft', mail: { fromName: target.name || target.email || '', subject: target.originalSubject || '', text: target.body || '' },
        template: { name: tpl.name, title: tpl.title, message: tpl.message }, current: text, instruction: q('#c-ai-hint').value });
      setText(result); aiMsg("Réponse proposée par l'IA : relis-la avant d'envoyer.");
    } catch (e) { aiMsg(e.message, true); }
    busy(false);
  });
  q('#c-ai-fix').addEventListener('click', async () => {
    if (!text.trim()) return;
    busy(true); aiMsg('Correction…');
    try {
      const result = await call('ai', { action: 'correct', text });
      correctedFor = result;
      if (result === text) aiMsg('Aucune faute trouvée ✓'); else { setText(result); aiMsg('Texte corrigé ✓'); }
    } catch (e) { aiMsg(e.message, true); }
    busy(false);
  });
  q('#c-ai-undo').addEventListener('click', () => {
    if (before === null) return;
    text = before; before = null; q('#c-text').value = text; q('#c-ai-undo').hidden = true; aiMsg(''); update();
  });
  // Correcteur auto avant l'envoi : si l'IA corrige quelque chose, on montre le texte avant d'envoyer.
  autoCorrectBeforeSend = async () => {
    if (state.autoCorrect === false || !text.trim() || correctedFor === text) return true;
    try {
      const result = await call('ai', { action: 'correct', text });
      correctedFor = result;
      if (result !== text) { setText(result); aiMsg("J'ai corrigé quelques fautes : vérifie l'aperçu puis clique à nouveau sur Envoyer."); return false; }
    } catch { /* IA indisponible : on envoie tel quel */ }
    return true;
  };
  host.addEventListener('keydown', (e) => { if (e.ctrlKey && e.key === 'Enter') { e.preventDefault(); send(); } });
  apply(template(target.template));
}

function openMessage(id) {
  const m = messages.find((x) => x.id === id);
  if (!m) { refresh(); return; }
  folder = isReplied(m) ? 'replied' : m.mailbox === 'news' ? 'news' : 'todo';
  search = ''; $('#search').value = '';
  selectedId = id; shownId = null;
  closeModals(); render();
}

async function refresh() {
  loading = !messages.length;
  render();
  try {
    const list = await call('refresh');
    setMessages(list);
    error = '';
  } catch (e) { error = e.message; }
  loading = false;
  render();
}

// ---------- fenêtres ----------
function closeModals() { document.querySelectorAll('.modal').forEach((m) => { m.hidden = true; }); }
document.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => { closeModals(); if (b.closest('#templates')) saveTemplates(); }));
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') closeModals();
  if (e.ctrlKey && e.key.toLowerCase() === 'r') { e.preventDefault(); refresh(); }
  if (e.ctrlKey && e.key.toLowerCase() === 'n') { e.preventDefault(); openNewMail(); }
  if (e.ctrlKey && e.key === ',') { e.preventDefault(); openSettings(); }
});

function renderSettings() {
  $('#inbox-saved').hidden = !state.inboxConfigured || inboxEditing;
  $('#inbox-edit').hidden = state.inboxConfigured && !inboxEditing;
  $('#brevo-saved').hidden = !state.brevoConfigured || brevoEditing;
  $('#brevo-edit').hidden = state.brevoConfigured && !brevoEditing;
  $('#notif').checked = state.notifications !== false;
  $('#team').value = state.teamName || '';
  $('#poll').value = String(state.pollMinutes || 2);
  $('#autocorrect').checked = state.autoCorrect !== false;
  $('#autoupdate').checked = state.autoUpdate !== false;
  renderUpdate();
}

// ---------- mise à jour par Internet ----------
let updateDismissed = false;
let updateMessage = '';
function renderUpdate() {
  const u = state.update || {};
  $('#version').textContent = `Version installée : ${u.currentVersion || '?'} (build ${u.currentBuild ?? 0})`;
  $('#update-status').textContent = updateMessage || (u.available ? `La version ${u.latestVersion} est disponible.` : u.latestVersion ? 'HN Mail est à jour.' : '');
  $('#update-install').hidden = !u.available;
  $('#update-banner').hidden = !u.available || updateDismissed;
  $('#update-banner-text').textContent = `HN Mail ${u.latestVersion || ''} est disponible (tu as la ${u.currentVersion || '?'})`;
}
async function installUpdate() {
  updateMessage = 'Téléchargement et installation… HN Mail va redémarrer.';
  renderUpdate();
  document.querySelectorAll('.update-install').forEach((b) => { b.disabled = true; });
  try { await call('installUpdate'); }
  catch (e) { updateMessage = e.message; renderUpdate(); document.querySelectorAll('.update-install').forEach((b) => { b.disabled = false; }); }
}
$('#update-check').addEventListener('click', async () => {
  updateMessage = 'Vérification…'; renderUpdate();
  try { state.update = await call('checkUpdate'); updateMessage = ''; }
  catch (e) { updateMessage = e.message; }
  renderUpdate();
});
document.querySelectorAll('.update-install').forEach((b) => b.addEventListener('click', installUpdate));
$('#update-later').addEventListener('click', () => { updateDismissed = true; renderUpdate(); });
$('#autocorrect').addEventListener('change', async (e) => { state = await call('setPrefs', { autoCorrect: e.target.checked }); });
$('#autoupdate').addEventListener('change', async (e) => { state = await call('setPrefs', { autoUpdate: e.target.checked }); });
let inboxEditing = false;
let brevoEditing = false;
function openSettings() { closeModals(); inboxEditing = false; brevoEditing = false; $('#settings-error').textContent = ''; renderSettings(); $('#settings').hidden = false; }
$('#open-settings').addEventListener('click', (e) => { e.preventDefault(); openSettings(); });
$('#inbox-change').addEventListener('click', () => { inboxEditing = true; renderSettings(); });
$('#brevo-change').addEventListener('click', () => { brevoEditing = true; renderSettings(); });
$('#inbox-generate').addEventListener('click', async () => {
  const key = await call('generateKey');
  $('#inbox-key').value = key; $('#inbox-key').type = 'text';
  $('#inbox-shown').textContent = key; $('#inbox-shown').hidden = false; $('#inbox-copy').hidden = false;
});
$('#inbox-copy').addEventListener('click', () => call('copy', { text: $('#inbox-key').value }));
$('#inbox-save').addEventListener('click', async () => {
  const key = $('#inbox-key').value.trim();
  if (key.length < 24) { $('#settings-error').textContent = 'La clé HN Mail fait au moins 24 caractères.'; return; }
  try { state = await call('saveInboxKey', { key }); inboxEditing = false; $('#inbox-key').value = ''; $('#inbox-key').type = 'password'; $('#inbox-shown').hidden = true; $('#inbox-copy').hidden = true; setMessages(state.messages); renderSettings(); render(); }
  catch (e) { $('#settings-error').textContent = e.message; }
});
$('#brevo-save').addEventListener('click', async () => {
  const key = $('#brevo-key').value.trim();
  if (key.length < 20) { $('#settings-error').textContent = 'Clé Brevo trop courte.'; return; }
  state = await call('saveBrevoKey', { key }); brevoEditing = false; $('#brevo-key').value = ''; renderSettings(); render();
});
$('#team').addEventListener('change', async (e) => { state = await call('setPrefs', { teamName: e.target.value }); render(); });
$('#notif').addEventListener('change', async (e) => { state = await call('setPrefs', { notifications: e.target.checked }); });
$('#poll').addEventListener('change', async (e) => { state = await call('setPrefs', { pollMinutes: Number(e.target.value) }); });

function openNewMail() {
  closeModals();
  $('#newmail').hidden = false;
  mountComposer($('#newmail-body'), { email: '', name: '', first: '', originalSubject: '', subject: '', inReplyTo: '', mailbox: 'contact', template: 'libre', messageId: '', editable: true });
}
$('#new').addEventListener('click', openNewMail);
$('#refresh').addEventListener('click', refresh);
$('#search').addEventListener('input', (e) => { search = e.target.value; render(); });
document.querySelectorAll('.side a[data-folder]').forEach((a) => a.addEventListener('click', (e) => { e.preventDefault(); folder = a.dataset.folder; selectedId = null; shownId = null; render(); }));
$('#list').addEventListener('click', (e) => { const item = e.target.closest('.item'); if (item) { selectedId = item.dataset.id; render(); } });

// ---------- gestion des templates ----------
let tplSel = null;
function saveTemplates() { call('saveTemplates', { templates }); shownId = null; renderMain(); }
function renderTemplates() {
  $('#tpl-list').innerHTML = templates.map((t) => `<li data-id="${esc(t.id)}" class="${t.id === tplSel ? 'on' : ''}">${esc(t.name)}<small>${esc(t.subtitle)}</small></li>`).join('');
  const t = templates.find((x) => x.id === tplSel);
  const ed = $('#tpl-editor');
  if (!t) { ed.innerHTML = '<p class="help">Choisis un modèle à gauche.</p>'; return; }
  ed.innerHTML = `<label>Nom<input data-f="name"></label><label>Sous-titre<input data-f="subtitle"></label>
    <label>Petit titre coloré<input data-f="eyebrow"></label><label>Titre<input data-f="title"></label>
    <label>Couleur<select data-f="accent"><option value="brand">Violet</option><option value="warning">Orange</option><option value="danger">Rouge</option><option value="success">Vert</option></select></label>
    <label>Message par défaut<textarea data-f="message"></textarea></label>
    <p class="help">{prenom} et {objet} sont remplacés automatiquement. Une ligne vide crée un nouveau paragraphe.</p>
    <label>Tableau d'informations</label><div id="tpl-rows"></div><button id="tpl-row-add">Ajouter une ligne</button>
    <label>Texte du bouton<input data-f="buttonLabel"></label><label>Lien (https://…)<input data-f="buttonURL"></label>
    <button id="tpl-delete">Supprimer ce modèle</button>`;
  ed.querySelectorAll('[data-f]').forEach((el) => { el.value = t[el.dataset.f] ?? ''; el.addEventListener('input', () => { t[el.dataset.f] = el.value; if (['name', 'subtitle'].includes(el.dataset.f)) renderTemplateList(); }); });
  const rows = () => {
    $('#tpl-rows').innerHTML = (t.rows || []).map((r, i) => `<div class="rowkv"><input data-i="${i}" data-k="key" placeholder="Intitulé"><input data-i="${i}" data-k="value" placeholder="Valeur"><button data-del="${i}">−</button></div>`).join('');
    $('#tpl-rows').querySelectorAll('input').forEach((el) => { el.value = t.rows[el.dataset.i][el.dataset.k]; el.addEventListener('input', () => { t.rows[el.dataset.i][el.dataset.k] = el.value; }); });
    $('#tpl-rows').querySelectorAll('[data-del]').forEach((b) => b.addEventListener('click', () => { t.rows.splice(Number(b.dataset.del), 1); rows(); }));
  };
  t.rows = t.rows || [];
  rows();
  $('#tpl-row-add').addEventListener('click', () => { t.rows.push({ key: '', value: '' }); rows(); });
  $('#tpl-delete').addEventListener('click', () => { templates = templates.filter((x) => x.id !== t.id); tplSel = templates[0]?.id; renderTemplates(); });
}
function renderTemplateList() {
  $('#tpl-list').querySelectorAll('li').forEach((li) => { const t = templates.find((x) => x.id === li.dataset.id); if (t) li.innerHTML = `${esc(t.name)}<small>${esc(t.subtitle)}</small>`; });
}
$('#tpl-list').addEventListener('click', (e) => { const li = e.target.closest('li'); if (li) { tplSel = li.dataset.id; renderTemplates(); } });
$('#tpl-add').addEventListener('click', () => {
  const t = { id: `t${Date.now()}`, name: 'Nouveau modèle', subtitle: '', eyebrow: 'Heivoli Network', title: 'Réponse à ton message', message: '', rows: [], buttonLabel: '', buttonURL: '', accent: 'brand' };
  templates.splice(Math.max(0, templates.length - 1), 0, t); tplSel = t.id; renderTemplates();
});
$('#tpl-reset').addEventListener('click', () => { templates = DEFAULT_TEMPLATES.map((t) => structuredClone(t)); tplSel = templates[0].id; renderTemplates(); });
$('#open-templates').addEventListener('click', (e) => { e.preventDefault(); closeModals(); tplSel = templates[0]?.id; renderTemplates(); $('#templates').hidden = false; });

// ---------- démarrage ----------
(async () => {
  state = await call('init');
  replied = state.replied || {};
  if (Array.isArray(state.templates) && state.templates.length) templates = state.templates;
  setMessages(state.messages);
  render();
  renderUpdate();
  if (state.inboxConfigured) refresh(); else openSettings();
})();
