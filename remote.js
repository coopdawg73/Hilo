const REMOTE_CONFIG = window.HILO_CONFIG || {};
const sb = (window.supabase && REMOTE_CONFIG.supabaseUrl && REMOTE_CONFIG.supabaseAnonKey && !String(REMOTE_CONFIG.supabaseUrl).includes("YOUR_PROJECT"))
  ? window.supabase.createClient(REMOTE_CONFIG.supabaseUrl, REMOTE_CONFIG.supabaseAnonKey)
  : null;

state.remote = {
  ready:false, uid:null, authError:null,
  screen:"home",
  matches:[], matchesStatus:"idle",
  activeMatchId:null, activeMatch:null,
  pendingTurn:null, turnResult:null,
  armedDouble:false, usedExtraTimeThisTurn:false, hint:null,
  powerupsUsed:{double:0, extra_time:0, fifty_fifty:0},
  timeLeft:20000, roundMs:20000, timerId:null, turnStartedAt:0,
  spinning:false, wheelRotation:0, wheelCategory:null,
  nameDraft:"", joinCodeDraft:"",
  lastMatchCode:null, lastMatchId:null,
  error:null, notice:null, busy:false
};

async function ensureRemoteSession(){
  if(!sb){ state.remote.authError = "Remote play needs a Supabase project configured in config.js."; return false; }
  const { data:{session} } = await sb.auth.getSession();
  if(session){ state.remote.uid = session.user.id; state.remote.ready = true; return true; }
  const { data, error } = await sb.auth.signInAnonymously();
  if(error){ state.remote.authError = error.message; return false; }
  state.remote.uid = data.user.id; state.remote.ready = true; return true;
}

async function initRemote(){
  if(!state.remote.ready && !state.remote.authError){
    const ok = await ensureRemoteSession();
    if(!ok){ render(); return; }
  }
  render();
  void refreshMatches();
}

async function refreshMatches(){
  if(!sb || !state.remote.ready) return;
  state.remote.matchesStatus = "loading";
  const { data, error } = await sb.from("matches").select("*").order("last_activity_at",{ascending:false});
  if(error){ state.remote.error = error.message; state.remote.matchesStatus = "error"; }
  else { state.remote.matches = data || []; state.remote.matchesStatus = "ready"; state.remote.error = null; }
  if(state.mode === "remote" && state.remote.screen === "home") render();
}

function remoteCrownBoard(){
  const m = state.remote.activeMatch; if(!m) return "";
  const crownsByCat = {}; (m.crowns || []).forEach(c => crownsByCat[c.category_key] = c.won_by);
  const nameFor = uid => uid === m.player1_id ? m.player1_name : m.player2_name;
  return `<div class="crown-board" aria-label="Crown standings">${CATEGORIES.map(c => {
    const owner = crownsByCat[c.key];
    return `<span class="crown-chip ${owner ? "owned" : ""}"><i style="color:${c.color};background:${c.color}"></i>${esc(c.label)}${owner ? ` <span class="owner">· ${esc(nameFor(owner))}</span>` : ""}</span>`;
  }).join("")}</div>`;
}

function remoteRouterView(){
  const r = state.remote;
  if(r.authError){
    return shell(`<section class="center-screen enter" aria-labelledby="rerr-title">${modeSwitchBar()}<p class="eyebrow"><i></i>Remote play</p><h1 id="rerr-title">Couldn’t<br><strong>connect</strong></h1><p>${esc(r.authError)}</p></section>`);
  }
  if(!r.ready){
    return shell(`<section class="center-screen enter"><p class="eyebrow"><i></i>Remote play</p><h1>Connecting…</h1></section>`);
  }
  switch(r.screen){
    case "invite": return remoteInviteView();
    case "join": return remoteJoinView();
    case "waiting": return remoteWaitingView();
    case "wheel": return remoteWheelView();
    case "turn": return remoteTurnView();
    case "results": return remoteResultsView();
    default: return remoteHomeView();
  }
}

function remoteHomeView(){
  const r = state.remote;
  const rows = r.matches.map(m => {
    const iAmP1 = m.player1_id === r.uid;
    const oppName = iAmP1 ? (m.player2_name || "Waiting…") : m.player1_name;
    const myScore = iAmP1 ? m.player1_score : m.player2_score;
    let badge;
    if(m.status === "pending") badge = `<span class="match-badge waiting">Invite sent</span>`;
    else if(m.status === "completed" || m.status === "abandoned"){
      const tied = !m.winner_id, won = m.winner_id === r.uid;
      badge = `<span class="match-badge done">${tied ? "Tie" : won ? "Won" : "Lost"}</span>`;
    } else if(m.turn_player_id === r.uid) badge = `<span class="match-badge your-turn">Your turn</span>`;
    else badge = `<span class="match-badge waiting">Waiting</span>`;
    return `<button type="button" class="match-row" data-remote-action="open-match" data-match-id="${m.id}"><div><h3>vs ${esc(oppName)}</h3><small>${formatScore(myScore)} pts</small></div>${badge}</button>`;
  }).join("");
  return shell(`<section class="setup enter" aria-labelledby="remote-title">
    <div class="hero"><p class="eyebrow"><i></i>Remote · crown rush with a friend</p><h1 id="remote-title">Play it<br><span>anywhere.</span></h1><p class="hero-copy">Create a match, send the link, and take turns whenever you get to it — no pass-the-phone required.</p></div>
    <div class="setup-side"><div class="setup-card panel">${modeSwitchBar()}
      <div class="card-title"><span class="step">🌐</span><div><p>Remote play</p><h2>Your matches</h2></div></div>
      ${r.error ? `<div class="remote-error">${esc(r.error)}</div>` : ""}
      ${r.notice ? `<p class="remote-note">${esc(r.notice)}</p>` : ""}
      <div class="names"><label><span>Your name</span><input id="remote-name" maxlength="14" autocomplete="nickname" value="${esc(r.nameDraft)}"></label></div>
      <button class="primary" type="button" data-remote-action="create" ${r.busy ? "disabled" : ""}>Create a match <b aria-hidden="true">→</b></button>
      <button class="ghost secondary" type="button" style="width:100%;margin-top:10px;" data-remote-action="show-join">Join with a code</button>
      <div class="match-list">${rows || `<div class="match-empty">No matches yet. Create one, or join a friend’s with their code.</div>`}</div>
    </div></div></section>`);
}

function remoteJoinView(){
  const r = state.remote;
  return shell(`<section class="center-screen enter" aria-labelledby="join-title"><p class="eyebrow"><i></i>Join a match</p><h1 id="join-title">Enter the<br><strong>invite code</strong></h1>
    <div class="setup-card panel" style="width:min(420px,100%);margin-top:24px;text-align:left;">
      ${r.error ? `<div class="remote-error">${esc(r.error)}</div>` : ""}
      <div class="names"><label><span>Invite code</span><input id="remote-join-code" maxlength="6" style="text-transform:uppercase;" value="${esc(r.joinCodeDraft)}"></label></div>
      <div class="names"><label><span>Your name</span><input id="remote-join-name" maxlength="14" value="${esc(r.nameDraft)}"></label></div>
      <button class="primary" type="button" data-remote-action="join" ${r.busy ? "disabled" : ""} style="width:100%;">Join match <b aria-hidden="true">→</b></button>
      <button class="ghost secondary" type="button" style="width:100%;margin-top:10px;" data-remote-action="back-home">Back</button>
    </div></section>`);
}

function remoteInviteView(){
  const r = state.remote;
  return shell(`<section class="center-screen enter" aria-labelledby="invite-title"><p class="eyebrow"><i></i>Match created</p><h1 id="invite-title">Send this<br><strong>to a friend</strong></h1>
    <p>They tap the link, enter their name, and you’re both in.</p>
    <div class="invite-code"><strong>${esc(r.lastMatchCode || "")}</strong><span>Invite code</span></div>
    ${r.notice ? `<p class="remote-note">${esc(r.notice)}</p>` : ""}
    <div class="center-action" style="display:grid;gap:10px;width:min(360px,100%);">
      <button class="primary" type="button" data-remote-action="share-invite">Share invite link <b aria-hidden="true">↗</b></button>
      <button class="ghost secondary" type="button" data-remote-action="back-home">Back to matches</button>
    </div>
    <small>Check back here once they’ve joined.</small></section>`);
}

function remoteWaitingView(){
  const m = state.remote.activeMatch;
  const oppName = m.player1_id === state.remote.uid ? m.player2_name : m.player1_name;
  return shell(`<section class="center-screen enter" aria-labelledby="waiting-title"><p class="eyebrow"><i></i>Waiting</p><h1 id="waiting-title">It’s<br><strong>${esc(oppName || "your opponent")}’s</strong> turn</h1><p>We’ll show your turn here as soon as it comes back around. Feel free to nudge them.</p>
    ${remoteCrownBoard()}
    <div class="center-action" style="display:grid;gap:10px;width:min(360px,100%);">
      <button class="ghost secondary" type="button" data-remote-action="nudge">Nudge ${esc(oppName || "them")} <b aria-hidden="true">↗</b></button>
      <button class="ghost secondary" type="button" data-remote-action="back-home">Back to matches</button>
    </div></section>`);
}

function remoteWheelView(){
  const r = state.remote;
  const n = CATEGORIES.length, step = 360/n;
  const gradient = `conic-gradient(${CATEGORIES.map((c,i) => `${c.color} ${i*step}deg ${(i+1)*step}deg`).join(",")})`;
  const landed = r.wheelCategory ? CATEGORIES.find(c => c.key === r.wheelCategory) : null;
  return shell(`<section class="center-screen enter" aria-labelledby="rwheel-title"><p class="eyebrow"><i></i>Your spin</p><h1 id="rwheel-title" style="font-size:clamp(40px,6vw,64px);">Spin for<br><span style="color:var(--lime)">a category</span></h1>
    <div class="wheel-stage" style="margin-top:8px;">
      <div class="wheel-frame"><div class="wheel-pointer" aria-hidden="true"></div><div class="wheel" id="remote-wheel" style="background:${gradient};transform:rotate(${r.wheelRotation}deg)"></div><div class="wheel-hub"><button type="button" data-remote-action="spin" ${r.spinning ? "disabled" : ""}>${r.spinning ? "…" : "Spin"}</button></div></div>
      <p class="wheel-result" aria-live="polite">${landed ? `Landed on ${esc(landed.label)}!` : ""}</p>
      ${remoteCrownBoard()}
    </div></section>`);
}

function remoteTurnView(){
  const r = state.remote, m = r.activeMatch, pending = r.pendingTurn, result = r.turnResult;
  const cat = CATEGORIES.find(c => c.key === pending.categoryKey);
  const q = pending.question, choices = QUESTION_TYPES[q.type];
  const reveal = !!result;
  const target = reveal ? result.target : q.target;
  const questionHtml = questionFor({type:q.type, known:q.known, target});
  const rightAnswer = reveal ? (result.target.value > q.known.value ? choices.up : choices.down) : "";
  const iAmP1 = m.player1_id === r.uid;
  const myName = iAmP1 ? m.player1_name : m.player2_name;
  const oppName = iAmP1 ? m.player2_name : m.player1_name;
  const myScore = (iAmP1 ? m.player1_score : m.player2_score) + (reveal ? result.points : 0);
  const oppScore = iAmP1 ? m.player2_score : m.player1_score;
  const seconds = (r.timeLeft/1000).toFixed(1);
  const timer = `<div class="timer ${r.timeLeft<=2500 ? "urgent" : ""}" id="remote-timer" role="progressbar" aria-label="Time remaining" aria-valuemin="0" aria-valuemax="${Math.round(r.roundMs/1000)}" aria-valuenow="${seconds}"><span>${reveal ? "Locked in" : "Time left"}</span><strong><span id="remote-timer-number">${seconds}</span><small>s</small></strong><div class="timer-track"><i id="remote-timer-fill" style="width:${(r.timeLeft/r.roundMs)*100}%"></i></div></div>`;
  const scoreBoard = `<div class="scores" aria-label="Scores"><div class="score active"><span>${esc(myName)}</span><strong>${formatScore(myScore)}</strong></div><div class="score"><span>${esc(oppName || "Opponent")}</span><strong>${formatScore(oppScore)}</strong></div></div>`;
  const powerupTray = reveal ? "" : `<div class="powerup-tray" role="group" aria-label="Power-ups">
    <button type="button" class="powerup-btn ${r.armedDouble ? "armed" : ""}" data-remote-powerup="double" ${r.armedDouble || r.powerupsUsed.double >= 2 ? "disabled" : ""}><span class="icon">2×</span>Double<span class="count">${2-r.powerupsUsed.double}</span></button>
    <button type="button" class="powerup-btn" data-remote-powerup="extra_time" ${r.usedExtraTimeThisTurn || r.powerupsUsed.extra_time >= 2 ? "disabled" : ""}><span class="icon">⏱</span>+6s<span class="count">${2-r.powerupsUsed.extra_time}</span></button>
    <button type="button" class="powerup-btn" data-remote-powerup="fifty_fifty" ${r.hint || r.powerupsUsed.fifty_fifty >= 2 ? "disabled" : ""}><span class="icon">?</span>Hint<span class="count">${2-r.powerupsUsed.fifty_fifty}</span></button>
    <button type="button" class="powerup-btn" data-remote-action="skip"><span class="icon">⏭</span>Skip</button>
  </div>`;
  return shell(`<section class="game enter" aria-labelledby="rgame-title"><div class="game-head"><p class="eyebrow"><i></i>${esc(cat.label)}${pending.isCrownAttempt ? " · CROWN CHALLENGE" : ""}</p><div class="solo-meta">${timer}${scoreBoard}</div></div>
    ${remoteCrownBoard()}
    <div class="question-banner"><span class="question-label">${esc(myName)}’s turn${pending.isCrownAttempt ? " · Crown at stake" : ""}</span><h1 id="rgame-title">${questionHtml}</h1></div>
    <div class="compare"><article class="fact known"><p>Known</p><h2>${esc(q.known.name)}</h2><div class="number lime">${esc(q.known.display)}</div><span class="unit">${esc(q.known.unit)}</span></article><div class="vs" aria-hidden="true">VS</div>
      <article class="fact mystery ${reveal ? (result.correct ? "correct" : "wrong") : ""}"><p>${reveal ? (result.correct === null ? "Skipped" : result.correct ? "Nice call" : "Not quite") : "Choose for this"}</p><h2>${esc(reveal ? result.target.name : q.target.name)}</h2>${reveal ? `<div class="answer" aria-live="polite"><div class="number violet">${esc(result.target.display)}</div><span class="unit">${esc(result.target.unit)}</span><div class="chip ${result.correct ? "right" : "miss"}">${result.correct ? `+${formatScore(result.points)} points${result.crown_won ? " · 👑 Crown claimed!" : ""}` : `Answer: ${esc(rightAnswer)}`}</div><button class="next" data-remote-action="after-turn">${result.match_status === "completed" ? "See final results" : "Back to matches"}<span aria-hidden="true">→</span></button></div>` : `${r.hint ? `<div class="hint-chip">${esc(r.hint)}</div>` : ""}<div class="guess-grid"><button class="guess higher" data-remote-guess="higher"><span>${esc(choices.up)}</span><b aria-hidden="true">↑</b></button><button class="guess lower" data-remote-guess="lower"><span>${esc(choices.down)}</span><b aria-hidden="true">↓</b></button></div>${powerupTray}`}</article></div>
  </section>`);
}

function remoteResultsView(){
  const r = state.remote, m = r.activeMatch;
  const tied = !m.winner_id, iWon = m.winner_id === r.uid;
  const iAmP1 = m.player1_id === r.uid;
  const myName = iAmP1 ? m.player1_name : m.player2_name;
  const oppName = iAmP1 ? m.player2_name : m.player1_name;
  const myScore = iAmP1 ? m.player1_score : m.player2_score;
  const oppScore = iAmP1 ? m.player2_score : m.player1_score;
  return shell(`<section class="center-screen results enter" aria-labelledby="rresults-title"><p class="eyebrow"><i></i>Match complete</p><div class="trophy" aria-hidden="true">👑</div>
    <h1 id="rresults-title">${tied ? "It’s a tie!" : iWon ? "You win!" : `${esc(oppName)} wins!`}</h1>
    ${remoteCrownBoard()}
    <div class="final-scores panel">
      <div class="final-player ${iWon ? "winner" : ""}"><span>${iWon ? "Winner" : "You"}</span><h2>${esc(myName)}</h2><strong>${formatScore(myScore)}</strong><small>points</small></div>
      <div class="final-player ${!tied && !iWon ? "winner" : ""}"><span>${!tied && !iWon ? "Winner" : "Opponent"}</span><h2>${esc(oppName || "Opponent")}</h2><strong>${formatScore(oppScore)}</strong><small>points</small></div>
    </div>
    <div class="result-actions"><button class="primary" data-remote-action="back-home">Back to matches <b aria-hidden="true">↻</b></button></div></section>`);
}

async function createRemoteMatch(){
  const nameInput = document.getElementById("remote-name");
  const name = cleanName(nameInput ? nameInput.value : state.remote.nameDraft, "Player");
  state.remote.nameDraft = name; state.remote.busy = true; state.remote.error = null; state.remote.notice = null; render();
  const { data, error } = await sb.rpc("create_remote_match", { p_player_name: name });
  state.remote.busy = false;
  if(error){ state.remote.error = error.message; render(); return; }
  const row = Array.isArray(data) ? data[0] : data;
  state.remote.lastMatchCode = row.match_code;
  state.remote.lastMatchId = row.match_id;
  state.remote.screen = "invite";
  render();
  void refreshMatches();
}

async function joinRemoteMatchByCode(){
  const codeInput = document.getElementById("remote-join-code");
  const nameInput = document.getElementById("remote-join-name");
  const code = (codeInput ? codeInput.value : state.remote.joinCodeDraft).trim().toUpperCase();
  const name = cleanName(nameInput ? nameInput.value : state.remote.nameDraft, "Player");
  if(!code){ state.remote.error = "Enter an invite code."; render(); return; }
  state.remote.joinCodeDraft = code; state.remote.nameDraft = name; state.remote.busy = true; state.remote.error = null; render();
  const { data, error } = await sb.rpc("join_remote_match", { p_match_code: code, p_player_name: name });
  state.remote.busy = false;
  if(error){ state.remote.error = error.message; render(); return; }
  await openRemoteMatch(data);
}

async function openRemoteMatch(matchId){
  state.remote.busy = true; state.remote.error = null; render();
  const { data: matchRow, error: matchErr } = await sb.from("matches").select("*").eq("id", matchId).single();
  if(matchErr || !matchRow){ state.remote.error = (matchErr && matchErr.message) || "Match not found"; state.remote.busy = false; render(); return; }
  const { data: crownRows } = await sb.from("match_crowns").select("category_key,won_by").eq("match_id", matchId);
  const { data: turnRows } = await sb.from("match_turns").select("used_double,used_extra_time,used_hint").eq("match_id", matchId).eq("player_id", state.remote.uid);
  state.remote.activeMatchId = matchId;
  state.remote.activeMatch = Object.assign({}, matchRow, { crowns: crownRows || [] });
  state.remote.powerupsUsed = {
    double: (turnRows || []).filter(t => t.used_double).length,
    extra_time: (turnRows || []).filter(t => t.used_extra_time).length,
    fifty_fifty: (turnRows || []).filter(t => t.used_hint).length
  };
  state.remote.busy = false;

  if(matchRow.status === "completed" || matchRow.status === "abandoned"){ state.remote.screen = "results"; render(); return; }
  if(matchRow.status === "pending"){ state.remote.lastMatchCode = matchRow.match_code; state.remote.screen = "invite"; render(); return; }
  if(matchRow.turn_player_id !== state.remote.uid){ state.remote.screen = "waiting"; render(); return; }

  const { data: openTurn } = await sb.rpc("get_open_turn", { p_match_id: matchId });
  const openRow = Array.isArray(openTurn) ? openTurn[0] : openTurn;
  if(openRow){
    state.remote.pendingTurn = { turnId: openRow.turn_id, categoryKey: openRow.category_key, isCrownAttempt: openRow.is_crown_attempt, question: openRow.question };
    state.remote.turnResult = null; state.remote.armedDouble = false; state.remote.hint = null; state.remote.usedExtraTimeThisTurn = false;
    state.remote.turnStartedAt = performance.now();
    state.remote.screen = "turn"; render(); startRemoteTimer(); return;
  }
  state.remote.screen = "wheel"; render();
}

function backToRemoteHome(){
  clearRemoteTimer();
  state.remote.screen = "home"; state.remote.activeMatchId = null; state.remote.activeMatch = null;
  state.remote.pendingTurn = null; state.remote.turnResult = null; state.remote.error = null; state.remote.wheelCategory = null;
  render(); void refreshMatches();
}

async function spinRemoteWheel(){
  if(state.remote.spinning) return;
  state.remote.spinning = true; state.remote.error = null; state.remote.wheelCategory = null; render();
  const { data, error } = await sb.rpc("spin_wheel", { p_match_id: state.remote.activeMatchId });
  if(error){ state.remote.spinning = false; state.remote.error = error.message; render(); return; }
  const row = Array.isArray(data) ? data[0] : data;
  const catIdx = CATEGORIES.findIndex(c => c.key === row.category_key);
  const wedge = 360/CATEGORIES.length, center = catIdx*wedge + wedge/2;
  const prev = state.remote.wheelRotation;
  const remainder = (((-center - prev) % 360) + 360) % 360;
  const target = prev + 5*360 + remainder;
  const wheelEl = document.getElementById("remote-wheel");
  requestAnimationFrame(() => { if(wheelEl) wheelEl.style.transform = `rotate(${target}deg)`; });
  setTimeout(() => {
    state.remote.spinning = false; state.remote.wheelRotation = target; state.remote.wheelCategory = row.category_key;
    state.remote.pendingTurn = { turnId: row.turn_id, categoryKey: row.category_key, isCrownAttempt: row.is_crown_attempt, question: row.question };
    state.remote.turnResult = null; state.remote.armedDouble = false; state.remote.hint = null; state.remote.usedExtraTimeThisTurn = false;
    state.remote.turnStartedAt = performance.now();
    state.remote.screen = "turn"; render(); startRemoteTimer();
  }, 3450);
}

function clearRemoteTimer(){ if(state.remote.timerId){ clearInterval(state.remote.timerId); state.remote.timerId = null; } }
function updateRemoteTimerDisplay(){
  const timer = document.getElementById("remote-timer"), number = document.getElementById("remote-timer-number"), fill = document.getElementById("remote-timer-fill");
  if(!timer || !number || !fill) return;
  const seconds = (state.remote.timeLeft/1000).toFixed(1);
  number.textContent = seconds; fill.style.width = `${(state.remote.timeLeft/state.remote.roundMs)*100}%`;
  timer.setAttribute("aria-valuenow", seconds); timer.classList.toggle("urgent", state.remote.timeLeft <= 2500);
}
function startRemoteTimer(){
  clearRemoteTimer();
  state.remote.roundMs = state.remote.usedExtraTimeThisTurn ? 30000 : 20000;
  state.remote.timeLeft = state.remote.roundMs;
  updateRemoteTimerDisplay();
  state.remote.timerId = setInterval(() => {
    state.remote.timeLeft = Math.max(0, state.remote.roundMs - (performance.now() - state.remote.turnStartedAt));
    updateRemoteTimerDisplay();
    if(state.remote.timeLeft <= 0){ clearRemoteTimer(); void finishRemoteTurn(null); }
  }, 50);
}

async function finishRemoteTurn(guess){
  if(!state.remote.pendingTurn || state.remote.turnResult) return;
  clearRemoteTimer();
  const elapsed = Math.round(performance.now() - state.remote.turnStartedAt);
  const { data, error } = await sb.rpc("submit_turn", { p_turn_id: state.remote.pendingTurn.turnId, p_guess: guess, p_elapsed_ms: elapsed });
  if(error){ state.remote.error = error.message; render(); return; }
  const row = Array.isArray(data) ? data[0] : data;
  state.remote.turnResult = row;
  buzz(row.correct === true);
  if(state.remote.activeMatch){
    if(state.remote.uid === state.remote.activeMatch.player1_id) state.remote.activeMatch.player1_score += row.points;
    else state.remote.activeMatch.player2_score += row.points;
    if(row.crown_won) state.remote.activeMatch.crowns.push({category_key: state.remote.pendingTurn.categoryKey, won_by: state.remote.uid});
    state.remote.activeMatch.status = row.match_status;
    state.remote.activeMatch.winner_id = row.winner_id;
  }
  render();
  void refreshMatches();
}

async function useRemotePowerUp(kind){
  const r = state.remote;
  if(!r.pendingTurn || r.turnResult) return;
  if(kind === "double" && r.armedDouble) return;
  if(kind === "extra_time" && r.usedExtraTimeThisTurn) return;
  if(kind === "fifty_fifty" && r.hint) return;
  if(r.powerupsUsed[kind] >= 2) return;
  const { data, error } = await sb.rpc("use_power_up", { p_turn_id: r.pendingTurn.turnId, p_kind: kind });
  if(error){ r.error = error.message; render(); return; }
  r.powerupsUsed[kind]++;
  if(kind === "double") r.armedDouble = true;
  if(kind === "extra_time"){ r.usedExtraTimeThisTurn = true; r.roundMs += 6000; }
  if(kind === "fifty_fifty") r.hint = data;
  render();
}

async function shareRemoteLink(matchCode, message){
  const link = `${location.origin}${location.pathname}?join=${matchCode}`;
  const text = message || `Your move in Hilo — ${link}`;
  if(navigator.share){
    try{ await navigator.share({ title:"Hilo", text, url:link }); return; }catch(e){ /* cancelled or unsupported, fall through to copy */ }
  }
  try{ await navigator.clipboard.writeText(link); state.remote.notice = "Invite link copied!"; render(); }
  catch(e){ state.remote.notice = link; render(); }
}

function bindRemote(){
  document.querySelectorAll("[data-remote-action]").forEach(el => el.addEventListener("click", () => {
    const action = el.dataset.remoteAction;
    if(action === "create") void createRemoteMatch();
    if(action === "show-join"){ state.remote.screen = "join"; state.remote.error = null; render(); }
    if(action === "join") void joinRemoteMatchByCode();
    if(action === "back-home") backToRemoteHome();
    if(action === "open-match") void openRemoteMatch(el.dataset.matchId);
    if(action === "spin") void spinRemoteWheel();
    if(action === "skip") void finishRemoteTurn(null);
    if(action === "share-invite") void shareRemoteLink(state.remote.lastMatchCode);
    if(action === "nudge"){ const m = state.remote.activeMatch; void shareRemoteLink(m.match_code, "Your move in Hilo!"); }
    if(action === "after-turn"){
      if(state.remote.turnResult && state.remote.turnResult.match_status === "completed"){ state.remote.screen = "results"; render(); }
      else backToRemoteHome();
    }
  }));
  document.querySelectorAll("[data-remote-guess]").forEach(el => el.addEventListener("click", () => void finishRemoteTurn(el.dataset.remoteGuess)));
  document.querySelectorAll("[data-remote-powerup]").forEach(el => el.addEventListener("click", () => void useRemotePowerUp(el.dataset.remotePowerup)));
  const nameInput = document.getElementById("remote-name"); if(nameInput) nameInput.addEventListener("input", () => state.remote.nameDraft = nameInput.value);
  const joinCode = document.getElementById("remote-join-code"); if(joinCode) joinCode.addEventListener("input", () => state.remote.joinCodeDraft = joinCode.value);
  const joinName = document.getElementById("remote-join-name"); if(joinName) joinName.addEventListener("input", () => state.remote.nameDraft = joinName.value);
}

document.addEventListener("visibilitychange", () => {
  if(document.visibilityState === "visible" && state.mode === "remote" && state.remote.screen === "home") void refreshMatches();
});

(function handleJoinParam(){
  const params = new URLSearchParams(location.search);
  const code = params.get("join");
  if(code){
    state.remote.joinCodeDraft = code.toUpperCase();
    state.mode = "remote"; state.screen = "remote"; state.remote.screen = "join";
    history.replaceState(null, "", location.pathname);
    render();
    void initRemote();
  }
})();
