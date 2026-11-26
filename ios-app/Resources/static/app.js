(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);

  const masterAudio = $('master-audio');
  const slaveVideo = $('slave-video');
  const watchSheet = $('watch-sheet');
  const playerStage = $('player-stage');
  const playerControls = $('player-controls');
  const playerSpinner = $('player-spinner');
  const seekSlider = $('seek-slider');
  const progressFill = $('progress-fill');
  const progressBuffer = $('progress-buffer');
  const miniProgressFill = $('mini-progress-fill');
  const timeDisplay = $('time-display');
  const mainContent = $('main-content');
  const chipsBar = $('chips-bar');

  const STORAGE_KEY = 'yt_personal_state_v1';

  const state = {
    tab: 'home',
    category: 'all',
    current: null,        // { id, title, channel, channelId, channelAvatar, thumbnail, durationSeconds, isLive, hlsUrl }
    related: [],
    qualities: [360, 720],
    quality: 720,
    playbackRate: 1,
    audioOnly: false,
    sponsorSkip: true,
    autoplay: true,
    loopMode: 'off',      // 'off' | 'all' | 'one'
    queue: [],
    playStack: [],        // previous videos for ⏮ button
    prefetchedId: null,
    controlsTimer: null,
    isScrubbing: false,
    sleepUntil: 0,        // timestamp ms, or -1 for end-of-track
    sleepTimerId: null,
    searchHistory: [],
    profile: {
      history: [],
      liked: [],
      watchLater: [],
      subscriptions: [],
      playlists: []
    },
    auth: {
      loggedIn: false,
      account: null,
      accounts: []
    },
    serverInfo: { lanUrl: location.origin, tunnelUrl: '' }
  };

  // -------------------------------------------------------------------------
  // Persistence (Local + Personal PC Sync)
  // -------------------------------------------------------------------------

  function loadLocalState() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return;
      const parsed = JSON.parse(raw);
      if (parsed.quality) state.quality = parsed.quality;
      if (typeof parsed.audioOnly === 'boolean') state.audioOnly = parsed.audioOnly;
      if (typeof parsed.sponsorSkip === 'boolean') state.sponsorSkip = parsed.sponsorSkip;
      if (typeof parsed.autoplay === 'boolean') state.autoplay = parsed.autoplay;
      if (parsed.loopMode) state.loopMode = parsed.loopMode;
      if (Array.isArray(parsed.searchHistory)) state.searchHistory = parsed.searchHistory;
      if (parsed.profile) state.profile = { ...state.profile, ...parsed.profile };
    } catch (_) {}
  }

  let syncTimeout = null;
  function saveState(syncRemote = true) {
    try {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({
          quality: state.quality,
          audioOnly: state.audioOnly,
          sponsorSkip: state.sponsorSkip,
          autoplay: state.autoplay,
          loopMode: state.loopMode,
          searchHistory: state.searchHistory.slice(0, 20),
          profile: state.profile
        })
      );
    } catch (_) {}

    if (syncRemote) {
      clearTimeout(syncTimeout);
      syncTimeout = setTimeout(() => {
        fetch('/api/profile', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(state.profile)
        }).catch(() => {});
      }, 600);
    }
  }

  async function syncProfileFromServer() {
    try {
      const reqs = [fetch('/api/profile'), fetch('/api/auth/status')];
      if (!window.__NATIVE_IOS__) reqs.push(fetch('/api/info'));
      const [profRes, authRes, infoRes] = await Promise.all(reqs);
      if (profRes && profRes.ok) {
        const remote = await profRes.json();
        for (const k of ['history', 'liked', 'watchLater', 'subscriptions']) {
          if (Array.isArray(remote[k]) && remote[k].length > (state.profile[k] || []).length) {
            state.profile[k] = remote[k];
          }
        }
        saveState(false);
      }
      if (infoRes && infoRes.ok) {
        state.serverInfo = await infoRes.json();
      }
      if (authRes && authRes.ok) {
        state.auth = await authRes.json();
        updateAccountTopBtn();
      }
    } catch (_) {}
  }

  function updateAccountTopBtn() {
    const btn = $('account-top-btn');
    if (!btn) return;
    if (state.auth && state.auth.loggedIn && state.auth.account) {
      const acc = state.auth.account;
      btn.classList.add('has-avatar');
      if (acc.avatar) {
        btn.innerHTML = `<img src="${esc(acc.avatar)}" alt="" referrerpolicy="no-referrer">`;
      } else {
        btn.textContent = (acc.name || 'G').charAt(0).toUpperCase();
      }
    } else {
      btn.classList.remove('has-avatar');
      btn.textContent = 'Đăng nhập';
    }
  }

  // -------------------------------------------------------------------------
  // Utilities
  // -------------------------------------------------------------------------

  function fmtTime(sec) {
    if (!Number.isFinite(sec) || sec < 0) return '0:00';
    const s = Math.floor(sec);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const r = s % 60;
    return h > 0
      ? `${h}:${String(m).padStart(2, '0')}:${String(r).padStart(2, '0')}`
      : `${m}:${String(r).padStart(2, '0')}`;
  }

  function esc(str) {
    const d = document.createElement('div');
    d.textContent = str == null ? '' : String(str);
    return d.innerHTML;
  }

  let toastTimer = null;
  function showToast(msg) {
    const el = $('toast');
    el.textContent = msg;
    el.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.add('hidden'), 2200);
  }

  function isStandaloneMode() {
    return (
      window.navigator.standalone === true ||
      window.matchMedia('(display-mode: standalone)').matches
    );
  }

  function getResumeRatio(videoId) {
    const item = state.profile.history.find((x) => x.id === videoId);
    if (!item || !item.progress || !item.durationSeconds) return 0;
    return Math.min(100, Math.max(5, Math.round((item.progress / item.durationSeconds) * 100)));
  }

  // -------------------------------------------------------------------------
  // Rendering Video Cards & Skeletons
  // -------------------------------------------------------------------------

  function renderSkeletons(container, count = 6) {
    container.innerHTML = Array.from({ length: count })
      .map(
        () => `
        <div class="video-card skeleton-card">
          <div class="thumb-wrap"></div>
          <div class="card-meta">
            <div class="skeleton-avatar"></div>
            <div class="card-info">
              <div class="skeleton-line"></div>
              <div class="skeleton-line short"></div>
            </div>
          </div>
        </div>`
      )
      .join('');
  }

  function renderVideoFeed(container, items) {
    if (!items || !items.length) {
      container.innerHTML = `<div class="empty-state">Không tìm thấy video nào.</div>`;
      return;
    }

    container.innerHTML = items
      .map((v, idx) => {
        const subParts = [v.channel, v.views, v.published].filter(Boolean).join(' · ');
        const initial = (v.channel || 'Y').trim().charAt(0).toUpperCase();
        const resumePct = v.resumePercent || getResumeRatio(v.id);
        const lazyAttr = idx < 6 ? '' : 'loading="lazy"';
        const avatarHtml = v.channelAvatar
          ? `<img src="${esc(v.channelAvatar)}" alt="" ${lazyAttr} referrerpolicy="no-referrer">`
          : esc(initial);
        const badgeCls = v.isLive ? 'duration-badge live' : 'duration-badge';

        return `
        <article class="video-card" data-vid="${esc(v.id)}">
          <div class="thumb-wrap">
            <img class="thumb-img" src="${esc(v.thumbnail)}" alt="" ${lazyAttr} referrerpolicy="no-referrer">
            ${v.duration ? `<span class="${badgeCls}">${esc(v.duration)}</span>` : ''}
            ${resumePct ? `<div class="resume-bar" style="width:${resumePct}%"></div>` : ''}
          </div>
          <div class="card-meta">
            <div class="avatar-circle" data-chid="${esc(v.channelId || '')}">${avatarHtml}</div>
            <div class="card-info">
              <h3 class="card-title">${esc(v.title)}</h3>
              <div class="card-sub">${esc(subParts)}</div>
            </div>
            <button class="card-more-btn" aria-label="Tùy chọn">⋮</button>
          </div>
        </article>`;
      })
      .join('');

    const byId = new Map(items.map((x) => [x.id, x]));
    container.querySelectorAll('.video-card').forEach((card) => {
      const vid = card.dataset.vid;
      const item = byId.get(vid);
      if (!item) return;

      card.addEventListener('click', (e) => {
        const moreBtn = e.target.closest('.card-more-btn');
        if (moreBtn) {
          e.stopPropagation();
          openVideoMenu(item);
          return;
        }
        const av = e.target.closest('.avatar-circle');
        if (av && av.dataset.chid) {
          e.stopPropagation();
          openChannel(av.dataset.chid, item.channel);
          return;
        }
        playVideo(item);
      });
    });
  }

  // -------------------------------------------------------------------------
  // Core Lock-Screen Background Audio + Synced Video Engine
  // -------------------------------------------------------------------------

  function streamUrl(videoId, type, quality, proxy = false) {
    const p = proxy ? '&proxy=1' : '';
    return type === 'audio'
      ? `/api/stream/${encodeURIComponent(videoId)}?type=audio${p}`
      : `/api/stream/${encodeURIComponent(videoId)}?type=video&q=${quality || state.quality}${p}`;
  }

  function updatePlayIcons(playing) {
    $('icon-play').classList.toggle('hidden', playing);
    $('icon-pause').classList.toggle('hidden', !playing);
    $('mini-icon-play').classList.toggle('hidden', playing);
    $('mini-icon-pause').classList.toggle('hidden', !playing);
    $('bg-pill').classList.toggle('hidden', !state.current || !playing);
    $('bg-pill-label').textContent = state.audioOnly ? 'Chỉ tiếng' : 'Nền ON';
  }

  function updateAudioModeUI() {
    const active = state.audioOnly;
    $('audio-mode-poster').classList.toggle('hidden', !active);
    $('audio-only-top-btn').classList.toggle('active', active);
    $('audio-mode-btn').classList.toggle('active', active);
    $('bg-pill-label').textContent = active ? 'Chỉ tiếng' : 'Nền ON';

    if (state.current) {
      $('audio-poster-bg').src = state.current.thumbnail;
      $('audio-poster-img').src = state.current.thumbnail;
    }

    if (active) {
      slaveVideo.pause();
      slaveVideo.removeAttribute('src');
      slaveVideo.load();
    } else if (state.current && !document.hidden && !watchSheet.classList.contains('minimized')) {
      attachAndSyncVideo(true);
    }
  }

  function attachAndSyncVideo(forceReload = false) {
    if (!state.current || state.audioOnly || state.current.isLive) return;
    if (document.hidden || watchSheet.classList.contains('minimized')) return;

    const targetSrc = streamUrl(state.current.id, 'video', state.quality);
    const currentPath = slaveVideo.getAttribute('data-src') || '';

    if (forceReload || currentPath !== targetSrc) {
      slaveVideo.setAttribute('data-src', targetSrc);
      slaveVideo.src = targetSrc;
      slaveVideo.playbackRate = state.playbackRate;
      const syncWhenReady = () => {
        if (Number.isFinite(masterAudio.currentTime) && masterAudio.currentTime > 0.2) {
          try { slaveVideo.currentTime = masterAudio.currentTime; } catch (_) {}
        }
        if (!masterAudio.paused) {
          slaveVideo.play().catch(() => {});
        }
      };
      slaveVideo.addEventListener('loadedmetadata', syncWhenReady, { once: true });
    } else {
      const drift = Math.abs(slaveVideo.currentTime - masterAudio.currentTime);
      if (drift > 0.35 && Number.isFinite(masterAudio.currentTime)) {
        try { slaveVideo.currentTime = masterAudio.currentTime; } catch (_) {}
      }
      if (!masterAudio.paused && slaveVideo.paused) {
        slaveVideo.play().catch(() => {});
      }
    }
  }

  function updateMediaSession() {
    if (!('mediaSession' in navigator) || !state.current) return;
    try {
      navigator.mediaSession.metadata = new MediaMetadata({
        title: state.current.title || 'YouTube',
        artist: state.current.channel || 'YouTube',
        album: 'YouTube Cá Nhân',
        artwork: [
          { src: `https://i.ytimg.com/vi/${state.current.id}/hqdefault.jpg`, sizes: '480x360', type: 'image/jpeg' },
          { src: state.current.thumbnail, sizes: '1280x720', type: 'image/jpeg' }
        ]
      });

      navigator.mediaSession.setActionHandler('play', () => {
        masterAudio.play().catch(() => {});
      });
      navigator.mediaSession.setActionHandler('pause', () => {
        masterAudio.pause();
      });
      navigator.mediaSession.setActionHandler('previoustrack', () => {
        playPrevious();
      });
      navigator.mediaSession.setActionHandler('nexttrack', () => {
        playNext(false);
      });
      navigator.mediaSession.setActionHandler('seekbackward', (d) => {
        seekRelative(-(d.seekOffset || 10));
      });
      navigator.mediaSession.setActionHandler('seekforward', (d) => {
        seekRelative(d.seekOffset || 10);
      });
      navigator.mediaSession.setActionHandler('seekto', (d) => {
        if (typeof d.seekTime === 'number') {
          seekToSeconds(d.seekTime);
        }
      });
    } catch (_) {}
  }

  function updatePositionState() {
    if (!('mediaSession' in navigator) || !navigator.mediaSession.setPositionState) return;
    const dur = masterAudio.duration;
    const pos = masterAudio.currentTime;
    if (Number.isFinite(dur) && dur > 0 && Number.isFinite(pos) && pos <= dur) {
      try {
        navigator.mediaSession.setPositionState({
          duration: dur,
          playbackRate: masterAudio.playbackRate || 1,
          position: pos
        });
      } catch (_) {}
    }
  }

  function recordHistory(item, progressSec = 0) {
    const existing = state.profile.history.find((x) => x.id === item.id);
    const entry = {
      id: item.id,
      title: item.title,
      channel: item.channel,
      channelId: item.channelId || '',
      channelAvatar: item.channelAvatar || '',
      thumbnail: item.thumbnail || `https://i.ytimg.com/vi/${item.id}/hq720.jpg`,
      duration: item.duration || '',
      durationSeconds: item.durationSeconds || (existing && existing.durationSeconds) || 0,
      progress: progressSec || (existing && existing.progress) || 0,
      watchedAt: Date.now()
    };
    state.profile.history = [
      entry,
      ...state.profile.history.filter((x) => x.id !== item.id)
    ].slice(0, 150);
    saveState(true);
  }

  function playVideo(item, opts = {}) {
    if (!item || !item.id) return;

    // Pause Shorts video if active
    stopShortsPlayback();

    if (state.current && state.current.id !== item.id && !opts.fromPrev) {
      state.playStack.push(state.current);
      if (state.playStack.length > 40) state.playStack.shift();
    }

    const prevSaved = state.profile.history.find((x) => x.id === item.id);
    const resumeAt =
      !opts.fromAutoNext &&
      prevSaved &&
      prevSaved.progress > 15 &&
      prevSaved.durationSeconds &&
      prevSaved.durationSeconds - prevSaved.progress > 20
        ? prevSaved.progress
        : 0;

    state.current = {
      id: item.id,
      title: item.title || 'Đang tải...',
      channel: item.channel || 'YouTube',
      channelId: item.channelId || '',
      channelAvatar: item.channelAvatar || '',
      thumbnail: item.thumbnail || `https://i.ytimg.com/vi/${item.id}/hq720.jpg`,
      duration: item.duration || '',
      durationSeconds: item.durationSeconds || 0,
      isLive: Boolean(item.isLive),
      sponsorSegments: [],
      description: ''
    };
    state.prefetchedId = null;
    lastSkippedEnd = -1;
    renderSponsorMarkers();

    // Show Watch Sheet immediately (keep minimized if auto-next happened while minimized/locked)
    watchSheet.classList.remove('hidden');
    if (!opts.fromAutoNext) {
      expandWatchSheet();
    }

    // 1. CRITICAL FOR iOS: Start masterAudio synchronously inside user gesture / ended tick!
    playerSpinner.classList.remove('hidden');
    masterAudio.playbackRate = state.playbackRate;
    masterAudio.dataset.proxyTried = '0';
    masterAudio.src = streamUrl(item.id, 'audio');
    if (resumeAt > 0) {
      masterAudio.addEventListener(
        'loadedmetadata',
        () => {
          try { masterAudio.currentTime = resumeAt; } catch (_) {}
        },
        { once: true }
      );
    }
    masterAudio.play().catch(() => {
      updatePlayIcons(false);
      playerSpinner.classList.add('hidden');
    });

    // 2. Attach synced muted H.264 video when visible and not in Audio-Only mode
    slaveVideo.dataset.proxyTried = '0';
    updateAudioModeUI();
    if (!state.audioOnly && !document.hidden && !watchSheet.classList.contains('minimized')) {
      attachAndSyncVideo(true);
    }

    // 3. Populate immediate UI & Lock Screen MediaSession
    renderWatchMeta();
    updateMediaSession();
    showControlsTemporarily();
    recordHistory(state.current, resumeAt);

    // 4. Fetch watch metadata, Up Next & SponsorBlock in parallel
    const activeId = item.id;
    fetch(`/api/watch/${encodeURIComponent(activeId)}`)
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error('watch failed'))))
      .then((detail) => {
        if (!state.current || state.current.id !== activeId) return;
        state.current = { ...state.current, ...detail };
        if (Array.isArray(detail.qualities) && detail.qualities.length) {
          state.qualities = detail.qualities;
          const avail = detail.qualities.filter((q) => q <= state.quality);
          const actualQ = avail.length ? avail[avail.length - 1] : detail.qualities[0];
          $('quality-btn').textContent = `${actualQ}p`;
        }
        state.related = detail.related || [];

        if (detail.isLive && detail.hlsUrl && masterAudio.error) {
          masterAudio.src = detail.hlsUrl;
          masterAudio.play().catch(() => {});
        }

        renderWatchMeta();
        renderSponsorMarkers();
        renderRelatedAndQueue();
        updateMediaSession();
        recordHistory(state.current, masterAudio.currentTime || 0);
      })
      .catch(() => {});
  }

  function renderSponsorMarkers() {
    const box = $('sponsor-markers');
    if (!box) return;
    const c = state.current;
    const dur = (c && c.durationSeconds) || masterAudio.duration || 0;
    const segs = (c && Array.isArray(c.sponsorSegments)) ? c.sponsorSegments : [];
    if (!state.sponsorSkip || !dur || !segs.length) {
      box.innerHTML = '';
      return;
    }
    box.innerHTML = segs
      .map((s) => {
        const left = Math.max(0, Math.min(100, (s.start / dur) * 100));
        const width = Math.max(0.4, Math.min(100 - left, ((s.end - s.start) / dur) * 100));
        return `<span class="sponsor-seg" style="left:${left}%;width:${width}%"></span>`;
      })
      .join('');
  }

  function renderWatchMeta() {
    const c = state.current;
    if (!c) return;
    $('watch-title').textContent = c.title;
    $('watch-views').textContent = c.views || '';
    $('watch-date').textContent = c.published || '';
    $('watch-channel-name').textContent = c.channel || 'YouTube';
    $('watch-subs-count').textContent = c.subscribers || '';

    const avEl = $('watch-avatar');
    if (c.channelAvatar) {
      avEl.innerHTML = `<img src="${esc(c.channelAvatar)}" alt="" referrerpolicy="no-referrer">`;
    } else {
      avEl.textContent = (c.channel || 'Y').charAt(0).toUpperCase();
    }

    $('mini-thumb').src = c.thumbnail;
    $('mini-title').textContent = c.title;
    $('mini-channel').textContent = c.channel;
    $('audio-poster-bg').src = c.thumbnail;
    $('audio-poster-img').src = c.thumbnail;

    const isLiked = state.profile.liked.some((x) => x.id === c.id);
    $('like-btn').classList.toggle('active', isLiked);
    $('like-btn').textContent = isLiked ? '👍 Đã thích' : '👍 Thích';

    const isSaved = state.profile.watchLater.some((x) => x.id === c.id);
    $('save-btn').classList.toggle('active', isSaved);
    $('save-btn').textContent = isSaved ? '✓ Đã lưu' : '➕ Nghe sau';

    const isSub = c.channelId && state.profile.subscriptions.some((s) => s.channelId === c.channelId);
    const subBtn = $('watch-sub-btn');
    subBtn.classList.toggle('subscribed', Boolean(isSub));
    subBtn.textContent = isSub ? 'Đã đăng ký' : 'Đăng ký';
  }

  function renderRelatedAndQueue() {
    const qBox = $('queue-box');
    const qList = $('queue-list');
    if (state.queue.length > 0) {
      qBox.classList.remove('hidden');
      $('queue-count').textContent = String(state.queue.length);
      qList.innerHTML = state.queue
        .map(
          (v, idx) => `
          <div class="compact-item" data-qidx="${idx}">
            <img src="${esc(v.thumbnail)}" alt="" loading="lazy" referrerpolicy="no-referrer">
            <div class="compact-info">
              <div class="compact-title">${esc(v.title)}</div>
              <div class="compact-sub">${esc(v.channel)}</div>
            </div>
            <button class="icon-btn q-remove" data-ridx="${idx}" aria-label="Xóa">✕</button>
          </div>`
        )
        .join('');
      qList.querySelectorAll('.compact-item').forEach((row) => {
        row.addEventListener('click', (e) => {
          const rm = e.target.closest('.q-remove');
          if (rm) {
            e.stopPropagation();
            state.queue.splice(Number(rm.dataset.ridx), 1);
            renderRelatedAndQueue();
            return;
          }
          const idx = Number(row.dataset.qidx);
          const chosen = state.queue.splice(idx, 1)[0];
          renderRelatedAndQueue();
          if (chosen) playVideo(chosen);
        });
      });
    } else {
      qBox.classList.add('hidden');
    }

    renderVideoFeed($('related-list'), state.related);
  }

  // -------------------------------------------------------------------------
  // Audio / Video Events, Drift Correction & Lock-Screen Transitions
  // -------------------------------------------------------------------------

  masterAudio.addEventListener('playing', () => {
    playerSpinner.classList.add('hidden');
    updatePlayIcons(true);
    if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
    if (!state.audioOnly && !document.hidden && !watchSheet.classList.contains('minimized')) {
      slaveVideo.play().catch(() => {});
    }
    updatePositionState();
  });

  masterAudio.addEventListener('pause', () => {
    updatePlayIcons(false);
    if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
    slaveVideo.pause();
  });

  masterAudio.addEventListener('waiting', () => {
    playerSpinner.classList.remove('hidden');
    slaveVideo.pause();
  });

  masterAudio.addEventListener('error', () => {
    if (!state.current) return;
    if (window.__NATIVE_IOS__ && masterAudio.dataset.proxyTried !== '1') {
      masterAudio.dataset.proxyTried = '1';
      masterAudio.src = streamUrl(state.current.id, 'audio', state.quality, true);
      masterAudio.play().catch(() => {});
      return;
    }
    playerSpinner.classList.add('hidden');
    updatePlayIcons(false);
    showToast('Không phát được luồng âm thanh, bấm Phát để thử lại');
  });

  slaveVideo.addEventListener('error', () => {
    if (!state.current || state.audioOnly) return;
    if (window.__NATIVE_IOS__ && slaveVideo.dataset.proxyTried !== '1') {
      slaveVideo.dataset.proxyTried = '1';
      const proxySrc = streamUrl(state.current.id, 'video', state.quality, true);
      slaveVideo.setAttribute('data-src', proxySrc);
      slaveVideo.src = proxySrc;
      slaveVideo.play().catch(() => {});
    }
  });

  masterAudio.addEventListener('ratechange', () => {
    slaveVideo.playbackRate = masterAudio.playbackRate;
    updatePositionState();
  });

  let lastProgressSave = 0;
  let lastSkippedEnd = -1;
  masterAudio.addEventListener('timeupdate', () => {
    const cur = masterAudio.currentTime || 0;
    const dur = masterAudio.duration || (state.current && state.current.durationSeconds) || 0;

    // Auto-skip baked-in sponsor/promo segments (works even while iPhone screen is locked)
    if (
      state.sponsorSkip &&
      !state.isScrubbing &&
      state.current &&
      Array.isArray(state.current.sponsorSegments)
    ) {
      for (const seg of state.current.sponsorSegments) {
        if (cur >= seg.start && cur < seg.end - 0.5 && Math.abs(lastSkippedEnd - seg.end) > 1.5) {
          lastSkippedEnd = seg.end;
          seekToSeconds(seg.end + 0.05);
          showToast('🛡️ Đã tự bỏ qua đoạn quảng cáo trong video');
          return;
        }
      }
    }

    if (dur > 0 && !state.isScrubbing) {
      const pct = Math.min(100, (cur / dur) * 100);
      progressFill.style.width = `${pct}%`;
      miniProgressFill.style.width = `${pct}%`;
      seekSlider.value = String(Math.round((cur / dur) * 1000));
      timeDisplay.textContent = `${fmtTime(cur)} / ${fmtTime(dur)}`;
    } else if (state.current && state.current.isLive) {
      timeDisplay.textContent = '🔴 TRỰC TIẾP';
    }

    if (masterAudio.buffered.length > 0 && dur > 0) {
      const bufEnd = masterAudio.buffered.end(masterAudio.buffered.length - 1);
      progressBuffer.style.width = `${Math.min(100, (bufEnd / dur) * 100)}%`;
    }

    // Soft lip-sync drift correction when video is visible
    if (
      !document.hidden &&
      !state.audioOnly &&
      !masterAudio.paused &&
      !watchSheet.classList.contains('minimized') &&
      slaveVideo.readyState >= 2
    ) {
      const drift = slaveVideo.currentTime - cur;
      if (Math.abs(drift) > 0.45) {
        try { slaveVideo.currentTime = cur; } catch (_) {}
        slaveVideo.playbackRate = state.playbackRate;
      } else if (drift > 0.09) {
        slaveVideo.playbackRate = state.playbackRate * 0.96;
      } else if (drift < -0.09) {
        slaveVideo.playbackRate = state.playbackRate * 1.04;
      } else if (slaveVideo.playbackRate !== state.playbackRate) {
        slaveVideo.playbackRate = state.playbackRate;
      }
      if (slaveVideo.paused) slaveVideo.play().catch(() => {});
    }

    // Pre-warm next track 28s before end so locked-screen transition takes <30ms
    if (dur > 0 && dur - cur < 28) {
      const candidate = peekNextTrack();
      if (candidate && candidate.id !== state.prefetchedId) {
        state.prefetchedId = candidate.id;
        fetch(`/api/prefetch/${encodeURIComponent(candidate.id)}`).catch(() => {});
      }
    }

    // Save resume position every 8s
    const now = Date.now();
    if (state.current && cur > 5 && now - lastProgressSave > 8000) {
      lastProgressSave = now;
      state.current.durationSeconds = Math.floor(dur || state.current.durationSeconds || 0);
      recordHistory(state.current, Math.floor(cur));
    }
  });

  masterAudio.addEventListener('ended', () => {
    if (state.sleepUntil === -1) {
      state.sleepUntil = 0;
      updateSleepUI();
      updatePlayIcons(false);
      return;
    }
    if (state.loopMode === 'one') {
      masterAudio.currentTime = 0;
      masterAudio.play().catch(() => {});
      return;
    }
    playNext(true);
  });

  // Screen Lock / Unlock handler: pause hidden video while locked to save battery;
  // masterAudio keeps playing seamlessly in iOS background!
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      slaveVideo.pause();
      updatePositionState();
    } else if (state.current && !state.audioOnly && !watchSheet.classList.contains('minimized')) {
      attachAndSyncVideo(false);
    }
  });

  function peekNextTrack() {
    if (state.queue.length > 0) return state.queue[0];
    if (state.autoplay && state.related.length > 0) return state.related[0];
    if (state.loopMode === 'all' && state.playStack.length > 0) return state.playStack[0];
    return null;
  }

  function playNext(fromAutoNext = false) {
    if (state.queue.length > 0) {
      const next = state.queue.shift();
      renderRelatedAndQueue();
      playVideo(next, { fromAutoNext });
      return;
    }
    if ((!fromAutoNext || state.autoplay) && state.related.length > 0) {
      playVideo(state.related[0], { fromAutoNext });
      return;
    }
    if (state.loopMode === 'all' && state.current) {
      masterAudio.currentTime = 0;
      masterAudio.play().catch(() => {});
    }
  }

  function playPrevious() {
    if (masterAudio.currentTime > 5) {
      seekToSeconds(0);
      return;
    }
    const prev = state.playStack.pop();
    if (prev) {
      playVideo(prev, { fromPrev: true });
    } else {
      seekToSeconds(0);
    }
  }

  function seekToSeconds(sec) {
    const dur = masterAudio.duration || (state.current && state.current.durationSeconds) || 0;
    const clamped = dur > 0 ? Math.max(0, Math.min(dur, sec)) : Math.max(0, sec);
    try { masterAudio.currentTime = clamped; } catch (_) {}
    if (!state.audioOnly && !document.hidden) {
      try { slaveVideo.currentTime = clamped; } catch (_) {}
    }
    updatePositionState();
  }

  function seekRelative(delta) {
    seekToSeconds((masterAudio.currentTime || 0) + delta);
    const rip = delta < 0 ? $('seek-ripple-left') : $('seek-ripple-right');
    rip.classList.remove('hidden');
    setTimeout(() => rip.classList.add('hidden'), 480);
  }

  // -------------------------------------------------------------------------
  // Player Controls, Gestures, Miniplayer & Sheets
  // -------------------------------------------------------------------------

  function showControlsTemporarily() {
    playerControls.classList.add('visible');
    clearTimeout(state.controlsTimer);
    if (!masterAudio.paused) {
      state.controlsTimer = setTimeout(() => {
        playerControls.classList.remove('visible');
      }, 3200);
    }
  }

  // Tap & Double-tap left/right +/-10s on player stage
  let lastStageTap = 0;
  let singleTapTimer = null;
  playerStage.addEventListener('click', (e) => {
    if (
      e.target.closest('button') ||
      e.target.closest('#progress-wrap')
    ) {
      return;
    }
    const now = Date.now();
    const rect = playerStage.getBoundingClientRect();
    const xRatio = (e.clientX - rect.left) / rect.width;

    if (now - lastStageTap < 280) {
      clearTimeout(singleTapTimer);
      lastStageTap = 0;
      if (xRatio < 0.42) seekRelative(-10);
      else if (xRatio > 0.58) seekRelative(10);
      return;
    }

    lastStageTap = now;
    singleTapTimer = setTimeout(() => {
      if (playerControls.classList.contains('visible')) {
        playerControls.classList.remove('visible');
      } else {
        showControlsTemporarily();
      }
    }, 230);
  });

  // Swipe down on player stage to minimize into Miniplayer
  let touchStartY = 0;
  playerStage.addEventListener('touchstart', (e) => {
    if (e.touches.length === 1) touchStartY = e.touches[0].clientY;
  }, { passive: true });

  playerStage.addEventListener('touchend', (e) => {
    if (!touchStartY || !e.changedTouches.length) return;
    const dy = e.changedTouches[0].clientY - touchStartY;
    touchStartY = 0;
    if (dy > 65) minimizeWatchSheet();
  }, { passive: true });

  function minimizeWatchSheet() {
    watchSheet.classList.add('minimized');
    $('mini-bar').classList.remove('hidden');
    slaveVideo.pause();
  }

  function expandWatchSheet() {
    watchSheet.classList.remove('minimized');
    $('mini-bar').classList.add('hidden');
    if (!state.audioOnly && !document.hidden) {
      attachAndSyncVideo(false);
    }
  }

  function closePlayer() {
    masterAudio.pause();
    masterAudio.removeAttribute('src');
    slaveVideo.pause();
    slaveVideo.removeAttribute('src');
    state.current = null;
    watchSheet.classList.add('hidden');
    updatePlayIcons(false);
  }

  $('minimize-btn').addEventListener('click', minimizeWatchSheet);
  $('mini-tap-area').addEventListener('click', expandWatchSheet);
  $('mini-close-btn').addEventListener('click', closePlayer);
  $('bg-pill').addEventListener('click', () => {
    if (state.current) {
      watchSheet.classList.remove('hidden');
      expandWatchSheet();
    }
  });

  function togglePlayPause() {
    if (!state.current) return;
    if (masterAudio.paused) {
      masterAudio.play().catch(() => {});
    } else {
      masterAudio.pause();
    }
    showControlsTemporarily();
  }

  $('play-pause-btn').addEventListener('click', togglePlayPause);
  $('mini-play-btn').addEventListener('click', togglePlayPause);
  $('prev-btn').addEventListener('click', playPrevious);
  $('next-btn').addEventListener('click', () => playNext(false));
  $('mini-next-btn').addEventListener('click', () => playNext(false));

  seekSlider.addEventListener('input', () => {
    state.isScrubbing = true;
    const dur = masterAudio.duration || (state.current && state.current.durationSeconds) || 0;
    const target = (Number(seekSlider.value) / 1000) * dur;
    progressFill.style.width = `${Number(seekSlider.value) / 10}%`;
    timeDisplay.textContent = `${fmtTime(target)} / ${fmtTime(dur)}`;
  });

  seekSlider.addEventListener('change', () => {
    const dur = masterAudio.duration || (state.current && state.current.durationSeconds) || 0;
    const target = (Number(seekSlider.value) / 1000) * dur;
    state.isScrubbing = false;
    seekToSeconds(target);
  });

  $('fullscreen-btn').addEventListener('click', () => {
    if (state.audioOnly) {
      state.audioOnly = false;
      saveState(false);
      updateAudioModeUI();
    }
    if (slaveVideo.webkitEnterFullscreen) {
      try { slaveVideo.webkitEnterFullscreen(); } catch (_) {}
    } else if (playerStage.requestFullscreen) {
      playerStage.requestFullscreen().catch(() => {});
    }
  });

  $('pip-btn').addEventListener('click', async () => {
    if (state.audioOnly) {
      state.audioOnly = false;
      updateAudioModeUI();
    }
    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture();
      } else if (slaveVideo.requestPictureInPicture) {
        await slaveVideo.requestPictureInPicture();
      } else if (slaveVideo.webkitSupportsPresentationMode) {
        slaveVideo.webkitSetPresentationMode(
          slaveVideo.webkitPresentationMode === 'picture-in-picture'
            ? 'inline'
            : 'picture-in-picture'
        );
      }
    } catch (_) {
      showToast('Hãy mở video trước khi bật Hình trong hình');
    }
  });

  function updateSponsorBtnUI() {
    const btn = $('sponsor-btn');
    if (!btn) return;
    btn.classList.toggle('active', state.sponsorSkip);
    btn.textContent = state.sponsorSkip ? '🛡️ Chặn QC: Bật' : '🛡️ Chặn QC: Tắt';
    renderSponsorMarkers();
  }

  $('sponsor-btn').addEventListener('click', () => {
    state.sponsorSkip = !state.sponsorSkip;
    saveState(false);
    updateSponsorBtnUI();
    showToast(state.sponsorSkip ? 'Đã bật tự nhảy qua quảng cáo tài trợ' : 'Đã tắt nhảy quảng cáo tài trợ');
  });

  // Watch Action Pills
  function toggleAudioOnly() {
    state.audioOnly = !state.audioOnly;
    saveState(false);
    updateAudioModeUI();
    showToast(state.audioOnly ? 'Đã bật Chế độ chỉ âm thanh' : 'Đã bật hình ảnh video');
  }
  $('audio-only-top-btn').addEventListener('click', toggleAudioOnly);
  $('audio-mode-btn').addEventListener('click', toggleAudioOnly);

  $('like-btn').addEventListener('click', () => {
    if (!state.current) return;
    const idx = state.profile.liked.findIndex((x) => x.id === state.current.id);
    if (idx >= 0) {
      state.profile.liked.splice(idx, 1);
      showToast('Đã bỏ thích');
    } else {
      state.profile.liked.unshift({ ...state.current });
      showToast('Đã thêm vào Video đã thích');
    }
    saveState(true);
    renderWatchMeta();
  });

  $('save-btn').addEventListener('click', () => {
    if (!state.current) return;
    const idx = state.profile.watchLater.findIndex((x) => x.id === state.current.id);
    if (idx >= 0) {
      state.profile.watchLater.splice(idx, 1);
      showToast('Đã xóa khỏi Nghe sau');
    } else {
      state.profile.watchLater.unshift({ ...state.current });
      showToast('Đã lưu vào Nghe sau');
    }
    saveState(true);
    renderWatchMeta();
  });

  $('watch-sub-btn').addEventListener('click', () => {
    const c = state.current;
    if (!c || !c.channelId) return;
    const idx = state.profile.subscriptions.findIndex((s) => s.channelId === c.channelId);
    if (idx >= 0) {
      state.profile.subscriptions.splice(idx, 1);
      showToast(`Đã hủy đăng ký ${c.channel}`);
    } else {
      state.profile.subscriptions.unshift({
        channelId: c.channelId,
        name: c.channel,
        avatar: c.channelAvatar || ''
      });
      showToast(`Đã đăng ký ${c.channel}`);
    }
    saveState(true);
    renderWatchMeta();
  });

  $('watch-channel-tap').addEventListener('click', () => {
    if (state.current && state.current.channelId) {
      minimizeWatchSheet();
      openChannel(state.current.channelId, state.current.channel);
    }
  });

  function updateLoopUI() {
    const map = { off: '🔁 Lặp: Tắt', all: '🔁 Lặp: Tất cả', one: '🔂 Lặp: 1 bài' };
    $('loop-btn').textContent = map[state.loopMode] || map.off;
    $('loop-btn').classList.toggle('active', state.loopMode !== 'off');
  }
  $('loop-btn').addEventListener('click', () => {
    const order = ['off', 'all', 'one'];
    state.loopMode = order[(order.indexOf(state.loopMode) + 1) % order.length];
    saveState(false);
    updateLoopUI();
  });

  $('autoplay-toggle').addEventListener('change', (e) => {
    state.autoplay = e.target.checked;
    saveState(false);
  });

  $('clear-queue-btn').addEventListener('click', () => {
    state.queue = [];
    renderRelatedAndQueue();
  });

  // -------------------------------------------------------------------------
  // Bottom Sheet Helpers (Quality, Speed, Sleep Timer, Description, Install)
  // -------------------------------------------------------------------------

  function openSheet(title, html, bindFn) {
    $('sheet-title').textContent = title;
    $('sheet-content').innerHTML = html;
    $('sheet-backdrop').classList.remove('hidden');
    $('bottom-sheet').classList.remove('hidden');
    if (bindFn) bindFn($('sheet-content'));
  }

  let authPollTimer = null;
  function closeSheet() {
    clearInterval(authPollTimer);
    authPollTimer = null;
    $('sheet-backdrop').classList.add('hidden');
    $('bottom-sheet').classList.add('hidden');
  }
  $('sheet-backdrop').addEventListener('click', closeSheet);

  $('quality-btn').addEventListener('click', () => {
    const qs = state.qualities.length ? state.qualities : [360, 480, 720, 1080];
    openSheet(
      'Chất lượng hình ảnh',
      qs
        .slice()
        .reverse()
        .map(
          (q) => `
          <button class="sheet-option" data-q="${q}">
            <span>${q}p ${q >= 720 ? 'HD' : ''}</span>
            <span>${q === state.quality ? '✓' : ''}</span>
          </button>`
        )
        .join(''),
      (root) => {
        root.querySelectorAll('.sheet-option').forEach((btn) => {
          btn.addEventListener('click', () => {
            state.quality = Number(btn.dataset.q);
            $('quality-btn').textContent = `${state.quality}p`;
            saveState(false);
            closeSheet();
            if (!state.audioOnly) attachAndSyncVideo(true);
            showToast(`Đã chọn ${state.quality}p`);
          });
        });
      }
    );
  });

  $('speed-btn').addEventListener('click', () => {
    const speeds = [0.75, 1, 1.25, 1.5, 1.75, 2];
    openSheet(
      'Tốc độ phát',
      speeds
        .map(
          (s) => `
          <button class="sheet-option" data-spd="${s}">
            <span>${s === 1 ? 'Chuẩn (1x)' : `${s}x`}</span>
            <span>${s === state.playbackRate ? '✓' : ''}</span>
          </button>`
        )
        .join(''),
      (root) => {
        root.querySelectorAll('.sheet-option').forEach((btn) => {
          btn.addEventListener('click', () => {
            state.playbackRate = Number(btn.dataset.spd);
            masterAudio.playbackRate = state.playbackRate;
            slaveVideo.playbackRate = state.playbackRate;
            $('speed-btn').textContent = `${state.playbackRate}x`;
            closeSheet();
          });
        });
      }
    );
  });

  function updateSleepUI() {
    const banner = $('sleep-banner');
    const btn = $('sleep-btn');
    clearInterval(state.sleepTimerId);

    if (!state.sleepUntil) {
      banner.classList.add('hidden');
      btn.classList.remove('active');
      btn.textContent = '🌙 Hẹn giờ';
      return;
    }

    btn.classList.add('active');
    if (state.sleepUntil === -1) {
      banner.textContent = '🌙 Sẽ tự dừng phát sau khi hết bài hiện tại.';
      banner.classList.remove('hidden');
      btn.textContent = '🌙 Hết bài';
      return;
    }

    const tick = () => {
      const rem = Math.max(0, Math.ceil((state.sleepUntil - Date.now()) / 1000));
      if (rem <= 0) {
        state.sleepUntil = 0;
        masterAudio.pause();
        updateSleepUI();
        showToast('Đã tự tắt nhạc theo hẹn giờ');
        return;
      }
      banner.textContent = `🌙 Tự động tắt nhạc sau ${fmtTime(rem)} (vẫn đếm khi khóa màn hình)`;
      banner.classList.remove('hidden');
      btn.textContent = `🌙 ${Math.ceil(rem / 60)}p`;
    };
    tick();
    state.sleepTimerId = setInterval(tick, 1000);
  }

  $('sleep-btn').addEventListener('click', () => {
    const opts = [
      { label: 'Tắt hẹn giờ', min: 0 },
      { label: 'Sau 15 phút', min: 15 },
      { label: 'Sau 30 phút', min: 30 },
      { label: 'Sau 45 phút', min: 45 },
      { label: 'Sau 60 phút', min: 60 },
      { label: 'Khi kết thúc video hiện tại', min: -1 }
    ];
    openSheet(
      'Hẹn giờ tắt khi ngủ',
      opts
        .map(
          (o) => `<button class="sheet-option" data-min="${o.min}"><span>${o.label}</span></button>`
        )
        .join(''),
      (root) => {
        root.querySelectorAll('.sheet-option').forEach((b) => {
          b.addEventListener('click', () => {
            const m = Number(b.dataset.min);
            state.sleepUntil = m === 0 ? 0 : m === -1 ? -1 : Date.now() + m * 60000;
            updateSleepUI();
            closeSheet();
          });
        });
      }
    );
  });

  $('watch-title-box').addEventListener('click', () => {
    if (!state.current) return;
    const c = state.current;
    openSheet(
      'Mô tả video',
      `<div class="desc-text"><strong>${esc(c.title)}</strong>\n${esc(
        [c.views, c.published].filter(Boolean).join(' • ')
      )}\n\n${esc(c.description || 'Không có mô tả chi tiết.')}</div>`
    );
  });

  function openVideoMenu(item) {
    openSheet(
      item.title,
      `
      <button class="sheet-option" data-act="next"><span>⏭ Phát tiếp theo</span></button>
      <button class="sheet-option" data-act="queue"><span>📋 Thêm vào cuối hàng chờ</span></button>
      <button class="sheet-option" data-act="later"><span>➕ Lưu vào Nghe sau</span></button>
      ${item.channelId ? `<button class="sheet-option" data-act="channel"><span>👤 Xem kênh ${esc(item.channel)}</span></button>` : ''}
      `,
      (root) => {
        root.querySelectorAll('.sheet-option').forEach((btn) => {
          btn.addEventListener('click', () => {
            const act = btn.dataset.act;
            closeSheet();
            if (act === 'next') {
              state.queue.unshift(item);
              if (state.current) renderRelatedAndQueue();
              showToast('Sẽ phát ngay bài tiếp theo');
            } else if (act === 'queue') {
              state.queue.push(item);
              if (state.current) renderRelatedAndQueue();
              showToast('Đã thêm vào hàng chờ');
            } else if (act === 'later') {
              if (!state.profile.watchLater.some((x) => x.id === item.id)) {
                state.profile.watchLater.unshift(item);
                saveState(true);
              }
              showToast('Đã lưu vào Nghe sau');
            } else if (act === 'channel' && item.channelId) {
              openChannel(item.channelId, item.channel);
            }
          });
        });
      }
    );
  }

  function openInstallGuide() {
    const activeUrl = state.serverInfo.tunnelUrl || location.origin;
    openSheet(
      'Cài thành App riêng trên iPhone',
      `<div class="desc-text" style="line-height:1.65">1. Mở địa chỉ này bằng <strong>Safari</strong> trên iPhone:\n<strong style="color:#3ea6ff">${esc(activeUrl)}</strong>\n\n2. Nhấn nút <strong>Chia sẻ (biểu tượng ô vuông có mũi tên lên ⬆️)</strong> ở thanh dưới Safari.\n\n3. Kéo xuống chọn <strong>"Thêm vào Màn hình chính" (Add to Home Screen)</strong> rồi nhấn <strong>Thêm</strong>.\n\nApp YouTube sẽ xuất hiện trên màn hình chính iPhone toàn màn hình giống hệt app gốc. Khi đang phát video hoặc nhạc, bạn bấm nút nguồn <strong>tắt màn hình iPhone</strong> âm thanh vẫn chạy liên tục không ngắt và điều khiển được ngay trên Màn hình khóa / Tai nghe AirPods.</div>`
    );
  }
  $('install-btn').addEventListener('click', openInstallGuide);

  // -------------------------------------------------------------------------
  // Navigation, Home, Search, Shorts, Subscriptions & Library
  // -------------------------------------------------------------------------

  function switchView(viewName) {
    const views = ['home', 'search', 'shorts', 'subs', 'you', 'channel'];
    views.forEach((v) => {
      $(`view-${v}`).classList.toggle('hidden', v !== viewName);
    });

    const showChips = viewName === 'home';
    chipsBar.classList.toggle('hidden', !showChips);
    $('topbar').classList.toggle('hidden', viewName === 'shorts');
    mainContent.classList.toggle('no-chips', !showChips && viewName !== 'shorts');
    mainContent.classList.toggle('shorts-mode', viewName === 'shorts');

    if (viewName !== 'shorts') {
      stopShortsPlayback();
    }

    document.querySelectorAll('.nav-tab').forEach((btn) => {
      btn.classList.toggle('active', btn.dataset.tab === viewName);
    });
  }

  document.querySelectorAll('.nav-tab').forEach((btn) => {
    btn.addEventListener('click', () => {
      const tab = btn.dataset.tab;
      state.tab = tab;
      switchView(tab);
      if (tab === 'home' && !$('home-feed').children.length) loadHome(state.category);
      if (tab === 'shorts') loadShorts();
      if (tab === 'subs') renderSubscriptionsView();
      if (tab === 'you') renderYouView();
    });
  });

  $('brand-home').addEventListener('click', () => {
    state.tab = 'home';
    switchView('home');
    window.scrollTo({ top: 0, behavior: 'smooth' });
  });

  // Home + Category Chips
  async function loadHome(category = 'all', forceRefresh = false) {
    state.category = category;
    const feed = $('home-feed');
    renderSkeletons(feed, 6);
    try {
      const url = `/api/home?category=${encodeURIComponent(category)}${forceRefresh ? '&refresh=1' : ''}`;
      const r = await fetch(url);
      const data = await r.json();
      if (!data.items || !data.items.length) {
        throw new Error('empty');
      }
      renderVideoFeed(feed, data.items);
    } catch (_) {
      feed.innerHTML = `<div class="empty-state">Không tải được video. Nhấn vào đây để thử lại.</div>`;
      feed.onclick = () => {
        feed.onclick = null;
        loadHome(category, true);
      };
    }
  }

  chipsBar.querySelectorAll('.chip').forEach((chip) => {
    chip.addEventListener('click', () => {
      chipsBar.querySelectorAll('.chip').forEach((c) => c.classList.remove('active'));
      chip.classList.add('active');
      window.scrollTo({ top: 0 });
      loadHome(chip.dataset.cat);
    });
  });

  // Search Overlay + Live Autocomplete
  const searchOverlay = $('search-overlay');
  const searchInput = $('search-input');
  const searchClear = $('search-clear-btn');
  const suggestBox = $('search-suggestions');

  function openSearchOverlay(prefill = '') {
    searchOverlay.classList.remove('hidden');
    searchInput.value = prefill;
    searchClear.classList.toggle('hidden', !prefill);
    renderSuggestions(prefill ? [] : state.searchHistory, true);
    setTimeout(() => searchInput.focus(), 30);
    if (prefill) fetchSuggestions(prefill);
  }

  function closeSearchOverlay() {
    searchOverlay.classList.add('hidden');
    searchInput.blur();
  }

  $('open-search-btn').addEventListener('click', () => openSearchOverlay(''));
  $('search-reopen-btn').addEventListener('click', () =>
    openSearchOverlay($('search-current-text').textContent || '')
  );
  $('search-back-btn').addEventListener('click', closeSearchOverlay);
  searchClear.addEventListener('click', () => {
    searchInput.value = '';
    searchClear.classList.add('hidden');
    renderSuggestions(state.searchHistory, true);
    searchInput.focus();
  });

  let suggestTimer = null;
  searchInput.addEventListener('input', () => {
    const val = searchInput.value.trim();
    searchClear.classList.toggle('hidden', !val);
    clearTimeout(suggestTimer);
    if (!val) {
      renderSuggestions(state.searchHistory, true);
      return;
    }
    suggestTimer = setTimeout(() => fetchSuggestions(val), 140);
  });

  async function fetchSuggestions(q) {
    try {
      const r = await fetch(`/api/suggest?q=${encodeURIComponent(q)}`);
      if (!r.ok) return;
      const list = await r.json();
      if (searchInput.value.trim() === q) {
        renderSuggestions(list, false);
      }
    } catch (_) {}
  }

  function renderSuggestions(list, isHistory) {
    suggestBox.innerHTML = (list || [])
      .map(
        (txt) => `
        <div class="suggest-row" data-q="${esc(txt)}">
          <span>${isHistory ? '🕒' : '🔍'}</span>
          <span class="suggest-text">${esc(txt)}</span>
          <button class="suggest-fill" data-fill="${esc(txt)}" aria-label="Điền từ khóa">↖</button>
        </div>`
      )
      .join('');

    suggestBox.querySelectorAll('.suggest-row').forEach((row) => {
      row.addEventListener('click', (e) => {
        const fill = e.target.closest('.suggest-fill');
        if (fill) {
          e.stopPropagation();
          searchInput.value = fill.dataset.fill;
          searchInput.focus();
          fetchSuggestions(searchInput.value);
          return;
        }
        executeSearch(row.dataset.q);
      });
    });
  }

  $('search-form').addEventListener('submit', (e) => {
    e.preventDefault();
    executeSearch(searchInput.value.trim());
  });

  async function executeSearch(query) {
    if (!query) return;
    closeSearchOverlay();
    state.searchHistory = [query, ...state.searchHistory.filter((x) => x !== query)].slice(0, 20);
    saveState(false);

    switchView('search');
    $('search-query-bar').classList.remove('hidden');
    $('search-current-text').textContent = query;
    const container = $('search-results');
    renderSkeletons(container, 6);

    try {
      const r = await fetch(`/api/search?q=${encodeURIComponent(query)}`);
      const data = await r.json();
      if (data.directVideoId && data.items && data.items[0]) {
        playVideo(data.items[0]);
      }
      renderVideoFeed(container, data.items || []);
    } catch (_) {
      container.innerHTML = `<div class="empty-state">Tìm kiếm thất bại, vui lòng thử lại.</div>`;
    }
  }

  // Shorts Vertical Swipe Feed
  let shortsObserver = null;
  let activeShortAudio = null;
  let activeShortVideo = null;

  function stopShortsPlayback() {
    if (activeShortAudio) {
      activeShortAudio.pause();
      activeShortAudio.removeAttribute('src');
    }
    if (activeShortVideo) {
      activeShortVideo.pause();
      activeShortVideo.removeAttribute('src');
    }
  }

  async function loadShorts() {
    const container = $('shorts-container');
    if (!masterAudio.paused) masterAudio.pause();

    if (!container.children.length) {
      container.innerHTML = `<div class="empty-state">Đang tải Shorts...</div>`;
      try {
        const r = await fetch('/api/shorts');
        const data = await r.json();
        const items = data.items || [];
        container.innerHTML = items
          .map(
            (v) => `
            <div class="short-slide" data-vid="${esc(v.id)}" data-json="${esc(JSON.stringify(v))}">
              <img class="short-poster" src="${esc(v.thumbnail)}" alt="" referrerpolicy="no-referrer">
              <div class="short-overlay">
                <div class="short-channel">@${esc(v.channel)}</div>
                <div class="short-title">${esc(v.title)}</div>
              </div>
              <div class="short-side-actions">
                <button class="short-act-btn act-bg">
                  <span class="short-act-circle">🎧</span>
                  <span>Phát nền</span>
                </button>
                <button class="short-act-btn act-like">
                  <span class="short-act-circle">👍</span>
                  <span>Thích</span>
                </button>
              </div>
            </div>`
          )
          .join('');

        container.querySelectorAll('.short-slide').forEach((slide) => {
          const item = JSON.parse(slide.dataset.json);
          slide.querySelector('.act-bg').addEventListener('click', (e) => {
            e.stopPropagation();
            stopShortsPlayback();
            state.tab = 'home';
            switchView('home');
            playVideo(item);
          });
          slide.querySelector('.act-like').addEventListener('click', (e) => {
            e.stopPropagation();
            if (!state.profile.liked.some((x) => x.id === item.id)) {
              state.profile.liked.unshift(item);
              saveState(true);
            }
            showToast('Đã thích Short');
          });
        });
      } catch (_) {
        container.innerHTML = `<div class="empty-state">Không tải được Shorts.</div>`;
        return;
      }
    }

    if (!activeShortAudio) {
      activeShortAudio = new Audio();
      activeShortAudio.loop = true;
    }

    if (shortsObserver) shortsObserver.disconnect();
    shortsObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting && state.tab === 'shorts') {
            activateShortSlide(entry.target);
          }
        });
      },
      { root: container, threshold: 0.68 }
    );
    container.querySelectorAll('.short-slide').forEach((s) => shortsObserver.observe(s));
  }

  function activateShortSlide(slide) {
    stopShortsPlayback();
    const vid = slide.dataset.vid;
    if (!vid) return;

    let vEl = slide.querySelector('video');
    if (!vEl) {
      vEl = document.createElement('video');
      vEl.muted = true;
      vEl.loop = true;
      vEl.playsInline = true;
      vEl.setAttribute('webkit-playsinline', '');
      slide.prepend(vEl);
      slide.addEventListener('click', () => {
        if (activeShortAudio.paused) {
          activeShortAudio.play().catch(() => {});
          vEl.play().catch(() => {});
        } else {
          activeShortAudio.pause();
          vEl.pause();
        }
      });
    }
    const poster = slide.querySelector('.short-poster');
    activeShortVideo = vEl;
    vEl.onplaying = () => {
      if (poster) poster.classList.add('hidden');
    };
    vEl.src = streamUrl(vid, 'video', 480);
    activeShortAudio.src = streamUrl(vid, 'audio');
    activeShortAudio.play().catch(() => {});
    vEl.play().catch(() => {});
  }

  // Channel View
  async function openChannel(browseId, fallbackName = '') {
    switchView('channel');
    const wrap = $('channel-content');
    wrap.innerHTML = `<div class="channel-header-box"><h2>${esc(fallbackName || 'Đang tải kênh...')}</h2></div><div id="ch-feed" class="video-feed"></div>`;
    renderSkeletons($('ch-feed'), 4);

    try {
      const r = await fetch(`/api/channel/${encodeURIComponent(browseId)}`);
      const ch = await r.json();
      const isSub = state.profile.subscriptions.some((s) => s.channelId === browseId);
      wrap.innerHTML = `
        <div class="channel-header-box">
          ${ch.banner ? `<img class="channel-banner" src="${esc(ch.banner)}" alt="" referrerpolicy="no-referrer">` : ''}
          <div class="watch-channel-row" style="padding:0">
            <div class="watch-channel-left">
              <div class="avatar-circle" style="width:52px;height:52px">
                ${ch.avatar ? `<img src="${esc(ch.avatar)}" alt="" referrerpolicy="no-referrer">` : esc((ch.name || 'Y')[0])}
              </div>
              <div>
                <div class="watch-channel-name" style="font-size:17px">${esc(ch.name)}</div>
                <div class="watch-subs-count">${(ch.items || []).length} video mới</div>
              </div>
            </div>
            <button id="ch-page-sub-btn" class="sub-btn ${isSub ? 'subscribed' : ''}">
              ${isSub ? 'Đã đăng ký' : 'Đăng ký'}
            </button>
          </div>
        </div>
        <div id="ch-feed" class="video-feed"></div>`;

      $('ch-page-sub-btn').addEventListener('click', (e) => {
        const idx = state.profile.subscriptions.findIndex((s) => s.channelId === browseId);
        if (idx >= 0) {
          state.profile.subscriptions.splice(idx, 1);
          e.target.classList.remove('subscribed');
          e.target.textContent = 'Đăng ký';
        } else {
          state.profile.subscriptions.unshift({
            channelId: browseId,
            name: ch.name,
            avatar: ch.avatar || ''
          });
          e.target.classList.add('subscribed');
          e.target.textContent = 'Đã đăng ký';
        }
        saveState(true);
      });

      renderVideoFeed($('ch-feed'), ch.items || []);
    } catch (_) {
      wrap.innerHTML = `<div class="empty-state">Không tải được kênh này.</div>`;
    }
  }

  // Google / Gmail Account Login & Channel Switcher
  async function openGoogleLoginModal() {
    openSheet(
      'Đăng nhập tài khoản Google (Gmail)',
      `<div class="desc-text">Đang tạo mã liên kết Google chính thức...</div>`
    );

    try {
      const r = await fetch('/api/auth/device/start', { method: 'POST' });
      if (!r.ok) throw new Error('start failed');
      const d = await r.json();

      openSheet(
        'Đăng nhập tài khoản Google (Gmail)',
        `
        <div class="desc-text">
          Nhấn nút bên dưới để tự sao chép mã và mở trang xác thực chính thức của Google. Chọn tài khoản Gmail của bạn rồi bấm <strong>Cho phép</strong>:
        </div>
        <div class="device-code-box" id="google-user-code">${esc(d.userCode)}</div>
        <button id="copy-and-open-google" class="google-btn-primary">
          📋 Sao chép mã & Mở trang Google
        </button>
        <div class="google-mini-actions">
          <button id="copy-code-only" class="action-pill">Sao chép mã</button>
          <span id="auth-poll-label" class="lib-row-sub" style="align-self:center">
            ⏳ Đang chờ bạn bấm Cho phép trên Google...
          </span>
        </div>
        `,
        (root) => {
          const copyCode = async () => {
            try {
              await navigator.clipboard.writeText(d.userCode);
              showToast(`Đã chép mã: ${d.userCode}`);
            } catch (_) {}
          };
          root.querySelector('#copy-code-only').addEventListener('click', copyCode);
          root.querySelector('#copy-and-open-google').addEventListener('click', async () => {
            await copyCode();
            window.open(d.verificationUrl || 'https://www.google.com/device', '_blank');
          });
        }
      );

      clearInterval(authPollTimer);
      authPollTimer = setInterval(async () => {
        try {
          const pr = await fetch('/api/auth/device/poll', { method: 'POST' });
          if (!pr.ok) return;
          const res = await pr.json();
          if (res.status === 'connected') {
            clearInterval(authPollTimer);
            authPollTimer = null;
            state.auth = {
              loggedIn: true,
              account: res.account,
              accounts: res.accounts || []
            };
            updateAccountTopBtn();
            closeSheet();
            showToast(`Đã đăng nhập: ${(res.account && res.account.name) || 'Google'}`);
            loadHome('all');
            state.tab = 'you';
            switchView('you');
            renderYouView();
          } else if (res.status === 'expired' || res.status === 'error') {
            clearInterval(authPollTimer);
            const lbl = $('auth-poll-label');
            if (lbl) lbl.textContent = 'Mã đã hết hạn, vui lòng mở lại.';
          }
        } catch (_) {}
      }, Math.max(3500, (d.interval || 4) * 800));
    } catch (_) {
      openSheet(
        'Đăng nhập Google',
        `<div class="desc-text">Không lấy được mã đăng nhập, vui lòng kiểm tra mạng và thử lại.</div>`
      );
    }
  }

  function openAccountSwitcherSheet() {
    const accounts = (state.auth && state.auth.accounts) || [];
    if (!accounts.length) return;
    const curPage = (state.auth.account && state.auth.account.pageId) || '';
    openSheet(
      'Chọn kênh trong tài khoản Gmail',
      accounts
        .map(
          (a, idx) => `
          <button class="sheet-option" data-aidx="${idx}">
            <span><strong>${esc(a.name)}</strong> ${a.handle ? `<small style="color:#aaa">${esc(a.handle)}</small>` : ''}</span>
            <span>${(a.pageId || '') === curPage && a.name === (state.auth.account && state.auth.account.name) ? '✓' : ''}</span>
          </button>`
        )
        .join(''),
      (root) => {
        root.querySelectorAll('.sheet-option').forEach((btn) => {
          btn.addEventListener('click', async () => {
            const chosen = accounts[Number(btn.dataset.aidx)];
            closeSheet();
            if (!chosen) return;
            const qs = `?pageId=${encodeURIComponent(chosen.pageId || '')}&name=${encodeURIComponent(chosen.name || '')}`;
            await fetch(`/api/auth/select-account${qs}`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ pageId: chosen.pageId || '', name: chosen.name || '' })
            });
            state.auth.account = chosen;
            updateAccountTopBtn();
            showToast(`Đã chuyển sang ${chosen.name}`);
            loadHome('all');
            renderYouView();
          });
        });
      }
    );
  }

  $('account-top-btn').addEventListener('click', () => {
    if (state.auth && state.auth.loggedIn) {
      state.tab = 'you';
      switchView('you');
      renderYouView();
    } else {
      openGoogleLoginModal();
    }
  });

  // Subscriptions View
  async function renderSubscriptionsView() {
    const wrap = $('subs-content');
    const subs = state.profile.subscriptions || [];

    if (!state.auth.loggedIn && !subs.length) {
      wrap.innerHTML = `
        <div class="empty-state">
          Bạn chưa đăng ký kênh nào.<br><br>
          <button id="subs-login-btn" class="sub-btn">Đăng nhập Gmail để đồng bộ kênh đăng ký</button>
        </div>`;
      $('subs-login-btn').addEventListener('click', openGoogleLoginModal);
      return;
    }

    wrap.innerHTML = `
      ${
        subs.length
          ? `<div class="subs-strip">
              ${subs
                .map(
                  (s) => `
                <div class="sub-avatar-item" data-cid="${esc(s.channelId)}" data-cname="${esc(s.name)}">
                  <div class="avatar-circle">
                    ${s.avatar ? `<img src="${esc(s.avatar)}" alt="" referrerpolicy="no-referrer">` : esc((s.name || 'K')[0])}
                  </div>
                  <span>${esc(s.name)}</span>
                </div>`
                )
                .join('')}
            </div>`
          : ''
      }
      <div id="subs-feed" class="video-feed" style="padding-top:12px"></div>`;

    wrap.querySelectorAll('.sub-avatar-item').forEach((el) => {
      el.addEventListener('click', () => openChannel(el.dataset.cid, el.dataset.cname));
    });

    const feedEl = $('subs-feed');
    renderSkeletons(feedEl, 6);
    try {
      const merged = [];
      const seen = new Set();

      if (state.auth.loggedIn) {
        const gr = await fetch('/api/account/subscriptions').then((r) => r.json());
        for (const v of gr.items || []) {
          if (!seen.has(v.id)) {
            seen.add(v.id);
            merged.push(v);
          }
        }
      }

      if (subs.length) {
        const lists = await Promise.all(
          subs.slice(0, 3).map((s) =>
            fetch(`/api/channel/${encodeURIComponent(s.channelId)}`)
              .then((r) => r.json())
              .then((d) => d.items || [])
              .catch(() => [])
          )
        );
        for (let i = 0; i < 10; i++) {
          for (const l of lists) {
            if (l[i] && !seen.has(l[i].id)) {
              seen.add(l[i].id);
              merged.push(l[i]);
            }
          }
        }
      }

      renderVideoFeed(feedEl, merged);
    } catch (_) {
      feedEl.innerHTML = `<div class="empty-state">Không tải được danh sách kênh đăng ký.</div>`;
    }
  }

  // Personal Library & Google Watch History ("Bạn") View
  async function renderYouView() {
    const wrap = $('you-content');
    const localHist = state.profile.history || [];
    const liked = state.profile.liked || [];
    const later = state.profile.watchLater || [];
    const acc = state.auth && state.auth.loggedIn ? state.auth.account : null;
    const multiAcc = state.auth && Array.isArray(state.auth.accounts) && state.auth.accounts.length > 1;

    wrap.innerHTML = `
      <div class="google-card">
        ${
          acc
            ? `<div class="google-user-row">
                <div class="avatar-circle" style="width:48px;height:48px">
                  ${acc.avatar ? `<img src="${esc(acc.avatar)}" alt="" referrerpolicy="no-referrer">` : esc((acc.name || 'G')[0])}
                </div>
                <div style="flex:1;min-width:0">
                  <div class="watch-channel-name" style="font-size:16px">${esc(acc.name)}</div>
                  <div class="watch-subs-count">${esc(acc.handle || 'Đã đồng bộ tài khoản Google ✓')}</div>
                </div>
              </div>
              <div class="google-mini-actions">
                ${multiAcc ? `<button id="switch-ch-btn" class="action-pill">🔄 Đổi kênh phụ</button>` : ''}
                <button id="refresh-hist-btn" class="action-pill">↻ Làm mới lịch sử</button>
                <button id="logout-google-btn" class="action-pill">Đăng xuất</button>
              </div>`
            : `<div class="watch-channel-name" style="font-size:16px;margin-bottom:4px">
                Đăng nhập tài khoản Google (Gmail)
              </div>
              <div class="lib-row-sub" style="line-height:1.45">
                Kết nối tài khoản Gmail của bạn để hiển thị toàn bộ <strong>Video đã xem</strong>, đề xuất Trang chủ và kênh đã đăng ký từ YouTube thật.
              </div>
              <button id="login-google-btn" class="google-btn-primary">
                Đăng nhập bằng Google
              </button>`
        }
      </div>

      <div class="section-row" style="padding:4px 0 6px">
        <h2 class="section-heading" style="font-size:18px">
          ${acc ? `Video đã xem (${esc(acc.name)})` : 'Video đã xem gần đây'}
        </h2>
        ${!acc && localHist.length ? `<button id="clear-hist-btn" class="text-btn">Xóa lịch sử</button>` : ''}
      </div>
      <div id="hist-rail-box">
        <p class="lib-row-sub" style="margin-bottom:16px">Đang tải lịch sử xem...</p>
      </div>

      <div class="lib-menu-card">
        <button class="lib-row" id="open-all-hist-btn">
          <span>📜 Xem toàn bộ Video đã xem</span>
          <span id="hist-count-label" class="lib-row-sub">Mở danh sách ›</span>
        </button>
        <button class="lib-row" id="open-liked-btn">
          <span>👍 Video đã thích</span>
          <span class="lib-row-sub">${acc ? 'Đồng bộ Google ›' : `${liked.length} video ›`}</span>
        </button>
        <button class="lib-row" id="open-later-btn">
          <span>🕐 Xem / Nghe sau</span>
          <span class="lib-row-sub">${later.length} video ›</span>
        </button>
        <button class="lib-row" id="open-install-row">
          <span>📱 Cài đặt ra Màn hình chính iPhone</span>
          <span class="lib-row-sub">${isStandaloneMode() ? 'Đã cài ✓' : 'Hướng dẫn ›'}</span>
        </button>
      </div>

      <div id="lib-list-section"></div>
    `;

    const loginBtn = $('login-google-btn');
    if (loginBtn) loginBtn.addEventListener('click', openGoogleLoginModal);

    const switchBtn = $('switch-ch-btn');
    if (switchBtn) switchBtn.addEventListener('click', openAccountSwitcherSheet);

    const refreshBtn = $('refresh-hist-btn');
    if (refreshBtn) refreshBtn.addEventListener('click', () => renderYouView());

    const logoutBtn = $('logout-google-btn');
    if (logoutBtn) {
      logoutBtn.addEventListener('click', async () => {
        await fetch('/api/auth/logout', { method: 'POST' });
        state.auth = { loggedIn: false, account: null, accounts: [] };
        updateAccountTopBtn();
        showToast('Đã đăng xuất tài khoản Google');
        renderYouView();
        loadHome('all');
      });
    }

    const clearBtn = $('clear-hist-btn');
    if (clearBtn) {
      clearBtn.addEventListener('click', () => {
        state.profile.history = [];
        saveState(true);
        renderYouView();
      });
    }

    $('open-install-row').addEventListener('click', openInstallGuide);

    // Load merged Google + local watch history
    let fullHistory = localHist;
    try {
      const hr = await fetch('/api/account/history');
      if (hr.ok) {
        const hd = await hr.json();
        if (Array.isArray(hd.items)) fullHistory = hd.items;
      }
    } catch (_) {}

    const railBox = $('hist-rail-box');
    const countLbl = $('hist-count-label');
    if (countLbl) countLbl.textContent = `${fullHistory.length} video ›`;

    if (railBox) {
      if (fullHistory.length) {
        railBox.innerHTML = `
          <div class="history-rail">
            ${fullHistory
              .slice(0, 24)
              .map((v) => {
                const pct = v.resumePercent || getResumeRatio(v.id);
                return `
                <div class="history-card" data-vid="${esc(v.id)}">
                  <div class="thumb-wrap">
                    <img class="thumb-img" src="${esc(v.thumbnail)}" alt="" loading="lazy" referrerpolicy="no-referrer">
                    ${v.duration ? `<span class="duration-badge">${esc(v.duration)}</span>` : ''}
                    ${pct ? `<div class="resume-bar" style="width:${pct}%"></div>` : ''}
                  </div>
                  <div class="history-card-title">${esc(v.title)}</div>
                </div>`;
              })
              .join('')}
          </div>`;
        const byHist = new Map(fullHistory.map((x) => [x.id, x]));
        railBox.querySelectorAll('.history-card').forEach((card) => {
          card.addEventListener('click', () => {
            const v = byHist.get(card.dataset.vid);
            if (v) playVideo(v);
          });
        });
      } else {
        railBox.innerHTML = `<p class="lib-row-sub" style="margin-bottom:18px">Chưa có video đã xem nào.</p>`;
      }
    }

    // Automatically display full watched list underneath when signed into Google!
    const sec = $('lib-list-section');
    if (acc && fullHistory.length && sec) {
      sec.innerHTML = `<h3 class="section-heading" style="margin:8px 0 12px">Tất cả video đã xem của tài khoản</h3><div id="sub-lib-feed" class="video-feed"></div>`;
      renderVideoFeed($('sub-lib-feed'), fullHistory);
    }

    $('open-all-hist-btn').addEventListener('click', () => {
      sec.innerHTML = `<h3 class="section-heading" style="margin:8px 0 12px">Tất cả video đã xem</h3><div id="sub-lib-feed" class="video-feed"></div>`;
      renderVideoFeed($('sub-lib-feed'), fullHistory);
      sec.scrollIntoView({ behavior: 'smooth' });
    });

    $('open-liked-btn').addEventListener('click', async () => {
      sec.innerHTML = `<h3 class="section-heading" style="margin:8px 0 12px">Video đã thích</h3><div id="sub-lib-feed" class="video-feed"></div>`;
      renderSkeletons($('sub-lib-feed'), 4);
      try {
        const lr = await fetch('/api/account/liked').then((r) => r.json());
        renderVideoFeed($('sub-lib-feed'), lr.items || liked);
      } catch (_) {
        renderVideoFeed($('sub-lib-feed'), liked);
      }
    });

    $('open-later-btn').addEventListener('click', () => {
      sec.innerHTML = `<h3 class="section-heading" style="margin:8px 0 12px">Xem / Nghe sau</h3><div id="sub-lib-feed" class="video-feed"></div>`;
      renderVideoFeed($('sub-lib-feed'), later);
    });
  }

  // -------------------------------------------------------------------------
  // Boot
  // -------------------------------------------------------------------------

  async function ensurePinUnlocked() {
    try {
      const r = await fetch('/api/pin/check');
      if (!r.ok) return true;
      const d = await r.json();
      if (!d.required || d.unlocked) return true;

      return await new Promise((resolve) => {
        openSheet(
          '🔒 Mở khóa YouTube Cá Nhân',
          `
          <div class="desc-text" style="margin-bottom:12px">
            Nhập mã PIN riêng của bạn (chỉ cần nhập 1 lần duy nhất trên iPhone này):
          </div>
          <form id="pin-form" style="display:flex;gap:8px">
            <input id="pin-input" type="password" inputmode="numeric" placeholder="Mã PIN..." style="flex:1;background:#141414;border:1px solid #383838;padding:11px 14px;border-radius:10px;font-size:16px">
            <button type="submit" class="sub-btn">Mở</button>
          </form>
          <div id="pin-err" class="lib-row-sub" style="color:#ff5c7c;margin-top:8px"></div>
          `,
          (root) => {
            root.querySelector('#pin-form').addEventListener('submit', async (e) => {
              e.preventDefault();
              const pin = root.querySelector('#pin-input').value.trim();
              const res = await fetch('/api/pin/unlock', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ pin })
              });
              if (res.ok) {
                closeSheet();
                resolve(true);
              } else {
                root.querySelector('#pin-err').textContent = 'Mã PIN không đúng, vui lòng thử lại.';
              }
            });
          }
        );
      });
    } catch (_) {
      return true;
    }
  }

  function init() {
    loadLocalState();
    $('quality-btn').textContent = `${state.quality}p`;
    $('autoplay-toggle').checked = state.autoplay;
    updateLoopUI();
    updateSponsorBtnUI();
    updateAudioModeUI();

    if (!isStandaloneMode() && !window.__NATIVE_IOS__) {
      $('install-btn').classList.remove('hidden');
    }

    if ('serviceWorker' in navigator && location.protocol === 'https:') {
      navigator.serviceWorker.register('/sw.js').catch(() => {});
    }

    if (window.__NATIVE_IOS__) {
      syncProfileFromServer();
      loadHome('all');
    } else {
      ensurePinUnlocked().then(() => {
        syncProfileFromServer();
        loadHome('all');
      });
    }
  }

  init();
})();
