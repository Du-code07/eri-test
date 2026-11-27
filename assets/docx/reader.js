import { applyDocxLayout, docxHeaderFooter, finalizeDocxLayout, fitDocxContent, settleDocxPageBreaks } from './docx_layout.js';
// Read-only adapter for OpenDocument.core. All assets and documents stay local.
const host = document.getElementById('pages');
const measure = document.getElementById('measure');
const MAX_BYTES = 256 * 1024 * 1024;
let incoming, received = 0, page = 0, pages = [], disposed = false;
let outlineBlockCache = null; // 목차용 문단 목록 (쪽을 다시 나누면 비움)
const IMAGE_CACHE_BYTES = 32 * 1024 * 1024;
const imageCache = new Map(), imageJobs = new Map(), brokenImages = new Set();
let resourceIndex = new Map(), originalSources = new Set(), resourceSession = 0;
let imageCacheBytes = 0, activeImagePaths = new Set(), renderSerial = 0;
let ready = false, requestId = 0, generation = 0, awaitingPassword = false, unavailableImages = 0;
let detectedFormat = 'docx';
let options = { format: 'docx', theme: 'white', spread: false, rtl: false, position: null, progress: 0 };
const requests = new Map(), fonts = new Map();
let pendingEvents = [], flushing = false;

function emit(type, data = {}) { pendingEvents.push({ type, ...data }); void flush(); retryBridge(); }
async function flush() {
  if (!window.flutter_inappwebview?.callHandler || flushing || disposed) return;
  flushing = true;
  try {
    while (pendingEvents.length && !disposed) {
      await window.flutter_inappwebview.callHandler('freaderDocx', pendingEvents[0]);
      pendingEvents.shift();
    }
  } catch (_) { /* Retry when the Android bridge becomes ready. */ }
  finally { flushing = false; }
}
// FReader(배터리): 보낼 알림이 남아 있을 때만 0.15초마다 다시 시도한다 (예전에는 책을 펴 둔 내내 계속 깨어 있었음)
let bridgeTimer = 0;
function retryBridge() {
  if (bridgeTimer || disposed) return;
  bridgeTimer = setInterval(() => {
    if (disposed || !pendingEvents.length) { clearInterval(bridgeTimer); bridgeTimer = 0; return; }
    void flush();
  }, 150);
}
window.addEventListener('flutterInAppWebViewPlatformReady', flush);
function fail(error) { emit('error', { message: String(error?.message || error).slice(0, 600) }); return false; }

const worker = new Worker('./worker.js', { type: 'module' });
worker.onmessage = ({ data }) => {
  if (disposed) return;
  if (data.id) { requests.get(data.id)?.(data); requests.delete(data.id); }
  else if (data.type === 'ready') { ready = true; emit('ready', { version: data.version }); }
  else if (data.type === 'error') fail(data.message);
};
worker.onerror = event => fail(event.message || 'Word 문서 엔진을 시작하지 못했어요');
function request(action, data = {}, transfer = []) {
  return new Promise(resolve => {
    const id = ++requestId; requests.set(id, resolve);
    worker.postMessage({ id, action, ...data }, transfer);
  });
}
// FReader: 문서를 다 읽어 쪽을 모두 만든 뒤에만 스크롤 보기를 켜고 끔
// (읽는 도중에 켜면 그때까지 만든 쪽만으로 스크롤 화면이 만들어져 스크롤이 중간에서 막혔음)
let docReady = false;
function clearPages() {
  docReady = false;
  renderSerial++;
  if (vertical) {
    vertical = false; vResize.disconnect(); vMounted.clear(); vOwner.clear();
    vhost?.remove(); vhost = null; vinner = null; vSlots = []; vTops = []; vRatios = []; host.style.display = '';
  }
  for (const item of imageCache.values()) URL.revokeObjectURL(item.url);
  imageCache.clear(); imageJobs.clear(); brokenImages.clear();
  resourceIndex.clear(); originalSources.clear(); activeImagePaths.clear(); imageCacheBytes = 0;
  pages = []; page = 0; unavailableImages = 0; host.replaceChildren(); measure.replaceChildren();
  searchState = { query: '', results: [], current: -1 }; applySearchHighlights();
  document.querySelectorAll('style[data-document]').forEach(el => el.remove());
}
function beginDocument(length, config) {
  if (!Number.isSafeInteger(length) || length < 1 || length > MAX_BYTES) throw new Error('열 수 있는 문서 크기는 256MB 이하예요');
  generation++; clearPages();
  if (incoming) incoming.fill(0);
  incoming = new Uint8Array(length); received = 0; awaitingPassword = false;
  imageStorePromise = null;
  configure(config);
}
function appendChunk(offset, encoded) {
  if (!incoming || offset !== received) throw new Error('문서 전송 순서가 올바르지 않아요');
  const binary = atob(encoded);
  if (received + binary.length > incoming.length) throw new Error('문서 전송 크기가 일치하지 않아요');
  for (let i = 0; i < binary.length; i++) incoming[received + i] = binary.charCodeAt(i);
  received += binary.length;
}
async function openDocument(password = null) {
  const current = generation;
  try {
    let result;
    if (awaitingPassword) result = await request('password', { password });
    else {
      if (!incoming || received !== incoming.length) throw new Error('문서 데이터를 모두 받지 못했어요');
      const bytes = incoming; incoming = null; received = 0;
      result = await request('open', { bytes, password, format: options.format }, [bytes.buffer]);
    }
    password = null;
    if (disposed || current !== generation) return false;
    if (result.type === 'password') { awaitingPassword = true; emit('password', { incorrect: result.incorrect }); return false; }
    awaitingPassword = false;
    if (result.type === 'error') return fail(result.message);
    detectedFormat = result.format || 'docx';
    resourceSession = result.session;
    resourceIndex = new Map((result.resources || []).map(r => [r.path, r]));
    await preparePages(result.html, current);
    if (disposed || current !== generation) return false;
    const saved = /^(?:docx|doc):(\d+)$/.exec(options.position || '');
    page = clampPage(saved ? Number(saved[1]) : Math.round(Number(options.progress || 0) * (pages.length - 1)));
    // 읽는 동안 바뀐 보기 설정(스크롤/쪽 넘김)을 여기서 한 번에 맞춤
    if (vertical) setVertical(false);
    if (options.vertical) setVertical(true); else await render();
    docReady = true;
    emit('loaded', { pageCount: pages.length, unavailableImages }); reportLocation();
    return true;
  } catch (error) { return fail(error); }
  finally { password = null; }
}

// 같은 크기(글자 폭)로 만든 무료 글꼴 (영문 부분만)
const METRIC_FONTS = [
  [/^(arial|helvetica|arimo|liberation sans)$/i, 'LiberationSans'],
  [/^(times new roman|times|tinos|liberation serif)$/i, 'LiberationSerif'],
  [/^(courier new|courier|cousine|liberation mono)$/i, 'LiberationMono'],
  [/^(calibri|carlito)$/i, 'Carlito'],
  [/^(cambria|caladea)$/i, 'Caladea'],
];
const LATIN_RANGE = 'U+0000-024F, U+2000-206F, U+20A0-20CF, U+2100-214F';
function metricFont(name) {
  const n = String(name).trim();
  for (const [re, base] of METRIC_FONTS) if (re.test(n)) return base;
  return null;
}
// 앱에 들어 있는 무료 한글 글꼴 (문서가 이 이름을 쓰면 원본 글꼴로 보여 줌)
const FREE_FONTS = [
  [/^(나눔고딕|nanumgothic|nanum gothic)$/i, 'NanumGothic', true],
  [/^(나눔명조|nanummyeongjo|nanum myeongjo)$/i, 'NanumMyeongjo', true],
  [/^(나눔고딕코딩|nanumgothiccoding|nanum gothic coding)$/i, 'NanumGothicCoding', true],
  [/^(고운바탕|gowunbatang|gowun batang)$/i, 'GowunBatang', true],
  [/^(고운돋움|gowundodum|gowun dodum)$/i, 'GowunDodum', false],
];
function freeFont(name) {
  const n = String(name).replace(/^DOCX /, '').trim();
  for (const [re, base, bold] of FREE_FONTS) if (re.test(n)) return { base, bold };
  return null;
}
async function addFreeFaces(name, free, dir) {
  await Promise.all((free.bold ? [400, 700] : [400]).map(async w => {
    try {
      const face = new FontFace(name, `url(${dir}/${free.base}-${w === 700 ? 'Bold' : 'Regular'}.woff2)`, { weight: String(w) });
      await face.load(); document.fonts.add(face);
    } catch (e) {}
  }));
}
// 한컴바탕·한컴돋움이 없으면 사용자가 넣은 함초롬바탕·함초롬돋움으로 대신 보여 줌
const USER_FONT_ALIASES = [
  [/^(한컴\s?바탕|hancom\s?batang|haansoft\s?batang)$/i, ['함초롬바탕', 'hcr batang', '함초롬 바탕']],
  [/^(한컴\s?돋움|hancom\s?dotum|haansoft\s?dotum)$/i, ['함초롬돋움', 'hcr dotum', '함초롬 돋움']],
];
function userFontFacesExact(n) {
  return (options.userFonts || []).filter(f => (f.n || []).some(x => String(x).trim().toLowerCase() === n));
}
function userFontFaces(name) {
  const n = String(name).trim().toLowerCase();
  const own = userFontFacesExact(n);
  if (own.length) return own;
  for (const [re, targets] of USER_FONT_ALIASES) {
    if (!re.test(n)) continue;
    for (const t of targets) {
      const faces = userFontFacesExact(t);
      if (faces.length) return faces;
    }
  }
  return [];
}
function fontKind(name) {
  if (/math|equation|수식/i.test(name)) return 'math';
  return /바탕|명조|궁서|batang|myeong|serif|times|cambria/i.test(name) ? 'serif' : 'sans';
}
async function loadFonts(root) {
  // Keep DOCX substitutions separate from the established DOC/RTF font aliases.
  if (detectedFormat === 'docx' && options.docxLayout?.version === 1) {
    for (const el of root.querySelectorAll('[style]')) {
      if (el.style.fontFamily) el.style.fontFamily = el.style.fontFamily.split(',').map(part => {
        const name = part.trim().replace(/^['"]|['"]$/g, '');
        return /^(sans-serif|serif|monospace|inherit|initial)$/i.test(name) ? name : JSON.stringify('DOCX ' + name);
      }).join(',');
    }
  }
  const names = new Set(['FReaderSans', 'FReaderSerif', '맑은 고딕', '바탕', '굴림', '돋움', 'Calibri', 'Arial', 'Times New Roman']);
  for (const el of root.querySelectorAll('[style]')) {
    for (const part of el.style.fontFamily.split(',')) {
      const name = part.trim().replace(/^['"]|['"]$/g, '');
      if (name && !/^(sans-serif|serif|monospace|inherit|initial)$/i.test(name)) names.add(name);
    }
  }
  await Promise.all([...names].slice(0, 128).map(async name => {
    if (fonts.has(name)) return fonts.get(name);
    if (name.length > 160 || /[\x00-\x1f]/.test(name)) return;
    const localName = name.startsWith('DOCX ') ? name.slice(5) : name;
    // 사용자가 넣은 글꼴이 있으면 그것을 씀 (기기에 없는 원래 글꼴 대신)
    const user = userFontFaces(localName);
    if (user.length) {
      const job = Promise.all(user.map(async f => {
        try {
          const face = new FontFace(name, `url(/userfonts/${encodeURIComponent(f.f)})`, { weight: String(f.w || 400), style: f.i ? 'italic' : 'normal' });
          await face.load(); document.fonts.add(face);
        } catch (e) {}
      }));
      fonts.set(name, job); return job;
    }
    const free = freeFont(localName);
    if (free) {
      const job = addFreeFaces(name, free, './fonts/free');
      fonts.set(name, job); return job;
    }
    const kind = fontKind(localName), base = kind === 'math' ? 'LatinModernMath' : kind === 'serif' ? 'NotoSerifKR' : 'NotoSansKR';
    const metric = kind === 'math' ? null : metricFont(localName);
    const job = Promise.all((kind === 'math' ? [400] : [400, 700]).map(async weight => {
      const suffix = weight === 700 ? 'Bold' : 'Regular';
      const face = new FontFace(name, `local(${JSON.stringify(localName)}), url(../hwp/fonts/${base}-${suffix}.woff2)`, { weight: String(weight) });
      await face.load(); document.fonts.add(face);
      if (kind !== 'math') {
        const symbols = new FontFace(name, `url(./fonts/${base}-Symbols-${suffix}.ttf)`, { weight: String(weight), unicodeRange: 'U+3000-303F' });
        await symbols.load(); document.fonts.add(symbols);
        if (metric) {
          // Arial·Times New Roman·Calibri 등: 글자 폭이 같은 무료 글꼴로 영문을 그려 줄바꿈·배치가 원본과 같게
          // 없어도 문서는 계속 보이게 (기본 글꼴로)
          try {
            const latin = new FontFace(name, `local(${JSON.stringify(localName)}), url(./fonts/metric/${metric}-${suffix}.woff2)`, { weight: String(weight), unicodeRange: LATIN_RANGE });
            await latin.load(); document.fonts.add(latin);
          } catch (e) {}
        } else if (name.startsWith('DOCX ')) {
        const latin = new FontFace(name, `local(${JSON.stringify(localName)}), url(./fonts/Noto${kind === 'serif' ? 'Serif' : 'Sans'}-Latin-${suffix}.ttf)`, { weight: String(weight), unicodeRange: 'U+0000-024F' });
        await latin.load(); document.fonts.add(latin);
        }
      }
    }));
    fonts.set(name, job); return job;
  }));
  await Promise.all(['400 16px FReaderSans', '700 16px FReaderSans', '400 16px FReaderSerif', '700 16px FReaderSerif', '400 16px FReaderMath'].map(font => document.fonts.load(font)));
}
function sanitize(parsed) {
  for (const img of parsed.querySelectorAll('img')) {
    const path = img.getAttribute('src');
    if (resourceIndex.has(path)) { img.dataset.resource = path; img.removeAttribute('src'); }
  }
  parsed.querySelectorAll('script,link,meta,base,iframe,object,embed,form').forEach(el => el.remove());
  for (const el of parsed.querySelectorAll('*')) {
    for (const attr of [...el.attributes]) {
      const name = attr.localName.toLowerCase();
      if (name.startsWith('on') || name === 'contenteditable' || name === 'srcdoc') el.removeAttributeNode(attr);
      else if (['href', 'src', 'srcset', 'action'].includes(name) &&
          !(name === 'src' && el.localName === 'img' && /^data:image\/(png|jpeg|jpg|gif|webp|bmp|svg\+xml)[;,]/i.test(attr.value))) el.removeAttributeNode(attr);
    }
  }
}
function applyPageBreaks(parsed) {
  const paragraphs = [...parsed.querySelectorAll('.odr-page-inner x-p')];
  for (const hint of options.pageBreaks || []) {
    const paragraph = paragraphs[hint.index];
    // A model difference must not split a different paragraph's contents.
    if (!paragraph || paragraph.textContent !== hint.text) continue;
    for (const offset of [...hint.offsets].sort((a, b) => b - a)) {
      if (offset === 0) { paragraph.style.breakBefore = 'column'; continue; }
      const walker = parsed.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
      let node, remaining = offset;
      while ((node = walker.nextNode())) {
        if (remaining > node.length) { remaining -= node.length; continue; }
        const range = parsed.createRange();
        range.setStart(node, remaining); range.setEnd(paragraph, paragraph.childNodes.length);
        const continuation = paragraph.cloneNode(false);
        continuation.appendChild(range.extractContents());
        continuation.style.breakBefore = 'column';
        paragraph.after(continuation);
        break;
      }
    }
  }
}
async function preparePages(html, current) {
  const parsed = new DOMParser().parseFromString(html, 'text/html');
  sanitize(parsed);
  // 편집 저장용: 원본 문단 순서(word/document.xml의 <w:p> 순서)를 쪽 나눔 전에 새겨 둠 (나뉜 문단 조각도 같은 번호를 물려받음)
  if (detectedFormat === 'docx') { let pi = 0; for (const p of parsed.querySelectorAll('.odr-pages x-p')) p.dataset.eriPi = String(pi++); }
  if (detectedFormat !== 'docx' || !applyDocxLayout(parsed, options.docxLayout)) applyPageBreaks(parsed);
  const sources = [...parsed.querySelectorAll('.odr-pages > .odr-page-outer')];
  if (!sources.length) throw new Error('Word 문서에서 표시할 본문을 찾지 못했어요');
  for (const style of parsed.head.querySelectorAll('style')) {
    const copy = document.createElement('style'); copy.dataset.document = '';
    copy.textContent = style.textContent; document.head.insertBefore(copy, document.querySelector('link'));
  }
  await loadFonts(parsed);
  if (disposed || current !== generation) return;
  for (const source of sources) {
    source.style.height = source.style.minHeight || '297mm';
    source.style.width ||= '210mm';
    if (detectedFormat === 'doc' || detectedFormat === 'rtf') {
      // The legacy/RTF parser has no paper/margin information. Use a readable
      // fallback while preserving its paragraphs and explicit page breaks.
      const inner = source.querySelector(':scope > .odr-page-inner');
      if (inner && !inner.style.margin) inner.style.margin = '20mm';
    }
    measure.appendChild(document.importNode(source, true));
  }
  finalizeDocxLayout(measure, options.docxLayout);
  originalSources = new Set(measure.children);
  // OOXML specifies the display extents. Reserve them without decoding every
  // photograph. Only unusual images without extents need an intrinsic-size probe.
  for (const img of measure.querySelectorAll('img')) {
    // FReader: 변환 엔진이 모든 그림에 붙이는 'Error: image not found' 대체 글자가
    // 그림을 불러오는 동안 보이지 않게 한다 (실제로 못 읽은 그림은 아래 missingImage가 따로 표시)
    if (/image not found/i.test(img.alt || '')) img.alt = '';
    if (!img.dataset.resource && !img.getAttribute('src')) { missingImage(img); continue; }
    if (!(parseFloat(img.style.width || img.getAttribute('width')) > 0) ||
        !(parseFloat(img.style.height || img.getAttribute('height')) > 0)) {
      try {
        const item = img.dataset.resource ? await imageFor(img.dataset.resource) : { url: img.src };
        if (disposed || current !== generation) return;
        const probe = new Image(); probe.src = item.url; await probe.decode();
        if (!img.style.width && !img.hasAttribute('width')) img.style.width = `${probe.naturalWidth}px`;
        if (!img.style.height && !img.hasAttribute('height')) img.style.height = `${probe.naturalHeight}px`;
        probe.src = ''; trimImages();
      } catch (_) { missingImage(img); }
    }
  }
  const result = [];
  let sectionOrder = 0;
  for (const source of measure.children) {
    const inner = source.querySelector(':scope > .odr-page-inner');
    if (!inner) throw new Error('Word 문서 본문 구조가 올바르지 않아요');
    if (source.classList.contains('rtf-paper')) {
      // Office reserves space for page furniture even when the saved margins
      // would otherwise overlap it. Measure after fonts and image extents load.
      for (const kind of ['header', 'footer']) {
        const furniture = source.querySelector('.rtf-page-' + kind);
        if (!furniture?.children.length) continue;
        let height = 0;
        for (const story of furniture.children) {
          for (const other of furniture.children) other.style.display = other === story ? 'block' : 'none';
          height = Math.max(height, furniture.getBoundingClientRect().height);
        }
        const edge = kind === 'header' ? 'Top' : 'Bottom';
        const offset = parseFloat(furniture.style[kind === 'header' ? 'top' : 'bottom']) || 0;
        inner.style['margin' + edge] = Math.max(parseFloat(inner.style['margin' + edge]) || 0, offset + height) + 'px';
      }
    }
    const bounds = source.getBoundingClientRect(), css = getComputedStyle(inner);
    const width = bounds.width, height = bounds.height;
    if (!(width > 0 && height > 0 && width < 20000 && height < 20000)) throw new Error('Word 문서 페이지 크기가 올바르지 않아요');
    const margin = ['Top', 'Right', 'Bottom', 'Left'].map(side => parseFloat(css['margin' + side]) || 0);
    const bodyWidth = Math.max(32, width - margin[1] - margin[3]);
    const bodyHeight = Math.max(32, height - margin[0] - margin[2]);
    if (inner.classList.contains('docx-layout')) {
      fitDocxContent(inner, bodyWidth, bodyHeight);
      // Chromium can fragment a short merged-cell table and leave border-only
      // fragments in later columns. Keep a table together if it fits one page;
      // long tables still paginate row by row without clipping their contents.
      for (const table of inner.querySelectorAll('table')) {
        if (table.getBoundingClientRect().height <= bodyHeight) table.style.breakInside = 'avoid';
      }
      for (const img of inner.querySelectorAll('img')) {
        const frame = img.parentElement;
        if (frame?.localName === 'div' && frame.getBoundingClientRect().height <= bodyHeight) frame.style.breakInside = 'avoid';
      }
    }

    // FReader: 머리말·꼬리말 (쪽 여백 자리에 그림)
    if (options.docxLayout?.sections?.length) {
      const secs = options.docxLayout.sections;
      const si = Math.min(secs.length - 1, Number(source.dataset.docxSection ?? sectionOrder));
      docxHeaderFooter(source, secs[si], options.docxLayout.theme || {}, { width, height, margin });
    }
    sectionOrder++;
    const clip = document.createElement('div'); clip.className = 'freader-content';
    Object.assign(clip.style, { left: `${margin[3]}px`, top: `${margin[0]}px`, width: `${bodyWidth}px`, height: `${bodyHeight}px` });
    inner.replaceWith(clip); clip.appendChild(inner);
    inner.classList.add('freader-columns');
    // Separate virtual pages so overflow ink from one column cannot be painted
    // onto the next. Tables/images are fitted above; the gap is never displayed.
    const columnGap = inner.classList.contains('docx-layout') ? bodyWidth : 0;
    const columnStride = bodyWidth + columnGap;
    Object.assign(inner.style, { width: `${bodyWidth}px`, height: `${bodyHeight}px`, columnWidth: `${bodyWidth}px`, columnGap: `${columnGap}px` });
    if (inner.classList.contains('docx-layout')) settleDocxPageBreaks(inner, columnStride);
    const columns = Math.max(1, Math.ceil((inner.scrollWidth + columnGap - 1) / columnStride));
    if (result.length + columns > 10000) throw new Error('표시할 Word 문서 페이지 수가 너무 많아요');
    // FReader: 쪽마다 들어 있는 그림 목록 (다음·이전 쪽 그림을 미리 불러오는 데 사용)
    const columnImages = Array.from({ length: columns }, () => new Set());
    const innerLeft = inner.getBoundingClientRect().left;
    for (const img of inner.querySelectorAll('img[data-resource]')) {
      for (const r of img.getClientRects()) {
        if (!(r.width > 0 && r.height > 0)) continue;
        const first = Math.floor((r.left - innerLeft + 0.5) / columnStride), last = Math.floor((r.right - innerLeft - 0.5) / columnStride);
        for (let c = Math.max(0, first); c <= Math.min(columns - 1, last); c++) columnImages[c].add(img.dataset.resource);
      }
    }
    // FReader: 스크롤 보기용 — 맨 위 글 덩어리마다 몇째 칸(쪽)에서 시작·끝나는지와 시작 칸 안의 높이
    // (스크롤 보기는 쪽마다 구역 전체를 복사하면 사진 많은 문서에서 매우 느려서, 그 쪽에 걸친 덩어리만 복사함)
    measureBlocks(source, inner, columns, columnStride);
    // FReader: 본문 자리 (여백 줄이기에서 이 자리가 화면에 크게 오도록 맞춤)
    const box = { x: margin[3], y: margin[0], w: bodyWidth, h: bodyHeight };
    for (let column = 0; column < columns; column++) result.push({ source, column, width, height, bodyWidth, columnStride, sectionPageCount: columns, box, images: [...columnImages[column]] });
  }
  pages = result; outlineBlockCache = null;
}
function clampPage(value) { return Math.max(0, Math.min(pages.length - 1, Number.isFinite(value) ? Math.trunc(value) : 0)); }
function reportLocation() { emit('location', { page, pageCount: pages.length, position: `${options.format === 'doc' ? 'doc' : 'docx'}:${page}`, progress: pages.length > 1 ? page / (pages.length - 1) : 1 }); }
function trimImages() {
  for (const [path, item] of imageCache) {
    if (imageCacheBytes <= IMAGE_CACHE_BYTES && imageCache.size <= 24) break;
    if (activeImagePaths.has(path)) continue;
    imageCache.delete(path); imageCacheBytes -= item.size; URL.revokeObjectURL(item.url);
  }
}
// ── 변환된 그림 저장소 (기기 안 Cache Storage, 문서마다 따로) ──
// 열쇠(cacheKey)는 앱이 파일 경로·크기·수정 시각으로 만들어 넘긴다. 문서가 바뀌면 열쇠도 바뀐다.
const IMAGE_STORE_PREFIX = 'freader-docx-img-v1-';
const IMAGE_STORE_KEEP = 40; // 최근 문서 40개까지만 보관
let imageStorePromise = null;
function imageStore() {
  if (!options.cacheKey || typeof caches === 'undefined') return Promise.resolve(null);
  if (!imageStorePromise) {
    const name = IMAGE_STORE_PREFIX + options.cacheKey;
    imageStorePromise = caches.open(name).then(store => { void pruneImageStores(name); return store; }).catch(() => null);
  }
  return imageStorePromise;
}
async function pruneImageStores(current) {
  try {
    let order = [];
    try { order = JSON.parse(localStorage.getItem('freaderDocxImgOrder') || '[]'); } catch (_) {}
    order = [current, ...order.filter(name => name !== current)];
    const keep = new Set(order.slice(0, IMAGE_STORE_KEEP));
    for (const name of await caches.keys()) if (name.startsWith(IMAGE_STORE_PREFIX) && !keep.has(name)) await caches.delete(name);
    try { localStorage.setItem('freaderDocxImgOrder', JSON.stringify([...keep])); } catch (_) {}
  } catch (_) {}
}
const storeUrl = path => `https://freader.local/img/${encodeURIComponent(path)}`;
async function storedImage(path) {
  try {
    const store = await imageStore(); if (!store) return null;
    const hit = await store.match(storeUrl(path)); if (!hit) return null;
    const blob = await hit.blob();
    return blob.size ? blob : null;
  } catch (_) { return null; }
}
async function storeImage(path, blob) {
  try {
    const store = await imageStore(); if (!store) return;
    await store.put(storeUrl(path), new Response(blob, { headers: { 'content-type': blob.type || 'application/octet-stream' } }));
  } catch (_) {}
}
async function imageFor(path) {
  if (brokenImages.has(path)) throw new Error('Unsupported image');
  if (imageCache.has(path)) {
    const item = imageCache.get(path); imageCache.delete(path); imageCache.set(path, item); return item;
  }
  if (imageJobs.has(path)) return imageJobs.get(path);
  const current = generation, requestedSession = resourceSession;
  const job = (async () => {
    // FReader: 한 번 꺼내고 변환한 그림은 기기에 저장해 두고 다음에 열 때 바로 쓴다
    const stored = await storedImage(path);
    let blob;
    if (stored) blob = stored;
    else {
      const result = await request('resource', { path, session: requestedSession });
      if (disposed || current !== generation || requestedSession !== resourceSession) throw new Error('Expired image');
      if (result.type !== 'resource' || !result.bytes) throw new Error(result.message || 'Missing image');
      blob = new Blob([result.bytes], { type: result.mimeType });
      void storeImage(path, blob);
    }
    if (disposed || current !== generation || requestedSession !== resourceSession) throw new Error('Expired image');
    const item = { url: URL.createObjectURL(blob), size: blob.size };
    imageCache.set(path, item); imageCacheBytes += item.size; return item;
  })();
  imageJobs.set(path, job);
  try { return await job; }
  finally { if (imageJobs.get(path) === job) imageJobs.delete(path); }
}
function missingImage(img, reason) {
  const key = img.dataset.resource || img.getAttribute('src') || 'missing';
  if (!brokenImages.has(key)) { brokenImages.add(key); unavailableImages++; }
  const notice = document.createElement('span');
  notice.className = 'freader-missing-image'; notice.dataset.resource = key; if (reason) notice.dataset.reason = String(reason); notice.style.cssText = img.style.cssText;
  notice.textContent = '이 그림은 표시할 수 없어요'; img.replaceWith(notice);
}
function preparePageSource(source, entry, index) {
    // 스크롤 보기의 가벼운 복사본은 이 쪽 앞뒤 글만 담고 있어 보일 칸 번호가 다름 (data-vcol)
    const column = source.dataset.vcol != null ? Number(source.dataset.vcol) : entry.column;
    source.querySelector('.freader-columns').style.transform = `translateX(${-column * entry.columnStride}px)`;
    // FReader: 머리말·꼬리말 쪽 번호와 첫 쪽 다른 머리말
    for (const field of source.querySelectorAll(':scope > .docx-hf [data-docx-field]')) {
      field.textContent = String(field.dataset.docxField === 'NUMPAGES' ? pages.length : index + 1);
    }
    const firstPage = entry.column === 0 && source.dataset.docxTitlePg === '1';
    for (const box of source.querySelectorAll(':scope > .docx-hf')) box.style.display = (box.dataset.hfType === 'first') === firstPage ? '' : 'none';
    if (source.classList.contains('rtf-paper')) {
      const start = Number(source.dataset.rtfStart), number = start > 0 ? start + entry.column : index + 1;
      for (const field of source.querySelectorAll('[data-rtf-field]')) {
        field.textContent = String(field.dataset.rtfField === 'NUMPAGES' ? pages.length : field.dataset.rtfField === 'SECTIONPAGES' ? entry.sectionPageCount : number);
      }
      for (const kind of ['header', 'footer']) {
        const furniture = source.querySelector('.rtf-page-' + kind); if (!furniture) continue;
        const suffix = source.dataset.rtfFirst === 'true' && entry.column === 0 ? 'f'
          : source.dataset.rtfFacing === 'true' ? (number % 2 ? 'r' : 'l') : '';
        const selected = furniture.querySelector(`[data-rtf-story="${kind + suffix}"]`)
          || (suffix !== 'f' ? furniture.querySelector(`[data-rtf-story="${kind}"]`) : null);
        for (const story of furniture.children) story.style.display = story === selected ? 'block' : 'none';
      }
    }
}
async function render() {
  if (zoomView) zoomClear(); // 다른 쪽으로 바뀌면 확대 끝 (밑그림도 버림)
  if (!pages.length || disposed) return;
  if (vertical) return;
  // 두 쪽 보기는 PDF처럼 늘 (1·2), (3·4)… 짝으로: 짝수 쪽에서 두 쪽 보기로 바꾸면 그 쪽이 오른쪽으로 (앞 짝과 겹치지 않게)
  if (options.spread && page % 2) { page -= 1; reportLocation(); }
  const serial = ++renderSerial;
  // Reuse the original layout tree in single-page mode. A spread only needs
  // one extra tree when both displayed pages belong to the same section.
  for (const frame of host.children) {
    for (const img of frame.querySelectorAll('img[data-resource]')) img.removeAttribute('src');
    const source = frame.firstElementChild;
    if (originalSources.has(source)) measure.appendChild(source);
  }
  const fragment = document.createDocumentFragment(), used = new Set();
  for (let index = page; index < Math.min(pages.length, page + (options.spread ? 2 : 1)); index++) {
    const entry = pages[index], frame = document.createElement('section');
    frame.className = 'page'; frame.dataset.page = String(index);
    frame.dataset.width = String(entry.width); frame.dataset.height = String(entry.height);
    if (entry.box) frame.dataset.box = JSON.stringify(entry.box);
    frame.setAttribute('aria-label', `${index + 1} / ${pages.length}`);
    const source = used.has(entry.source) ? entry.source.cloneNode(true) : entry.source; used.add(entry.source);
    preparePageSource(source, entry, index);
    frame.appendChild(source); fragment.appendChild(frame);
  }
  // FReader: 두 쪽 보기에서 마지막 쪽이 홀로 남으면 책처럼 왼쪽에 두고 오른쪽은 비워 둠
  if (options.spread && fragment.childElementCount === 1) {
    const only = fragment.firstElementChild, spacer = document.createElement('div');
    spacer.className = 'page-spacer'; spacer.dataset.width = only.dataset.width; spacer.dataset.height = only.dataset.height;
    if (only.dataset.box) spacer.dataset.box = only.dataset.box;
    Object.assign(spacer.style, { flex: 'none', visibility: 'hidden' });
    fragment.appendChild(spacer);
  }
  host.replaceChildren(fragment); fitPages();
  renderNoteAreas();
  applySearchHighlights();
  const visible = [...host.querySelectorAll('img[data-resource]')].filter(img => {
    const clip = (img.closest('.freader-content') || img.closest('.page')).getBoundingClientRect();
    return [...img.getClientRects()].some(r => r.width > 0 && r.height > 0 && r.right > clip.left + .1 && r.left < clip.right - .1 && r.bottom > clip.top + .1 && r.top < clip.bottom - .1);
  });
  activeImagePaths = new Set(visible.map(img => img.dataset.resource));
  trimImages();
  // FReader: 글자는 바로 보이게 하고(쪽 위치도 바로 알림), 사진은 이어서 채운다.
  // 사진까지 다 채워지면 'pageReady'를 알린다 (앱은 이때 이 쪽의 화면을 저장해 다음에 먼저 띄움).
  void loadVisibleImages(serial, visible);
}
/** 고친 뒤(되돌리기 포함): 보이는 그림의 주소를 지금 쓸 수 있는 주소로 다시 채움 */
async function loadFrameImagesFresh(frame) {
  const imgs = [...frame.querySelectorAll('img[data-resource]')].filter(img => {
    const clip = (img.closest('.freader-content') || img.closest('.page')).getBoundingClientRect();
    return [...img.getClientRects()].some(r => r.width > 0 && r.height > 0 && r.right > clip.left + .1 && r.left < clip.right - .1 && r.bottom > clip.top + .1 && r.top < clip.bottom - .1);
  });
  for (const img of imgs) {
    if (disposed || !frame.isConnected) return;
    try { const item = await imageFor(img.dataset.resource); if (img.getAttribute('src') !== item.url) img.src = item.url; } catch (_) {}
  }
}
async function loadVisibleImages(serial, visible) {
  // Bounded decoding keeps temporary pixel buffers small for photo-heavy files.
  // FReader: 두 장씩 함께 불러와 사진이 많은 쪽도 빨리 채운다.
  const queue = [...visible];
  const worker = async () => {
    while (queue.length) {
      const img = queue.shift();
      if (disposed || serial !== renderSerial) return;
      try {
        const item = await imageFor(img.dataset.resource);
        if (disposed || serial !== renderSerial) return;
        img.loading = 'eager'; img.src = item.url; await img.decode();
      } catch (error) { if (!disposed && serial === renderSerial) missingImage(img, error); }
    }
  };
  await Promise.all([worker(), worker()]);
  if (disposed || serial !== renderSerial) return;
  trimImages();
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  if (disposed || serial !== renderSerial) return;
  emit('pageReady', { page, position: `${options.format === 'doc' ? 'doc' : 'docx'}:${page}` });
  prefetchNearby(serial);
}
// FReader: 지금 쪽을 다 그린 뒤 다음 쪽(두 쪽 보기면 두 쪽)과 이전 쪽의 그림을 미리 준비해 둔다.
// 그림 변환(벡터 그림 등)은 오래 걸리므로 넘기는 순간 빈 칸으로 보이지 않게 한다.
async function prefetchNearby(serial) {
  const span = options.spread ? 2 : 1;
  const order = [page + span, page + span + 1, page - 1, page + 2 * span, page - span - 1];
  const wanted = [];
  for (const index of order) {
    if (index < 0 || index >= pages.length || index === page) continue;
    for (const path of pages[index].images || []) if (!wanted.includes(path)) wanted.push(path);
  }
  for (const path of wanted.slice(0, 16)) {
    if (disposed || serial !== renderSerial) return;
    if (imageCache.has(path) || brokenImages.has(path)) continue;
    try {
      const item = await imageFor(path);
      // 사진은 미리 풀어 두면 넘길 때 바로 보인다 (크기가 큰 것은 메모리를 아끼기 위해 건너뜀)
      if (item.size < 6 * 1024 * 1024 && serial === renderSerial) {
        const probe = new Image(); probe.src = item.url; await probe.decode().catch(() => {});
      }
    } catch (_) {}
    if (imageCacheBytes > IMAGE_CACHE_BYTES * 0.9) break;
  }
}
// FReader: 이 쪽에 보이는 각주 번호의 본문을 쪽 아래에 표시 (Word처럼 본문 아래, 자리가 없으면 아래 여백)
function renderNoteAreas(frames = realFrames()) {
  const notes = options.docxLayout?.notes;
  for (const frame of frames) {
    const source = frame.firstElementChild; if (!source) continue;
    for (const old of source.querySelectorAll(':scope > .docx-note-area')) old.remove();
    if (!notes) continue;
    const clipEl = source.querySelector(':scope > .freader-content'); if (!clipEl) continue;
    const clip = clipEl.getBoundingClientRect();
    const inside = r => r.width > 0 && r.height > 0 && r.right > clip.left + .1 && r.left < clip.right - .1 && r.bottom > clip.top + .1 && r.top < clip.bottom - .1;
    const seen = new Set(), items = [];
    for (const ref of clipEl.querySelectorAll('sup.docx-note-ref')) {
      if (![...ref.getClientRects()].some(inside)) continue;
      const key = ref.dataset.noteKey; if (seen.has(key) || notes[key] == null) continue;
      seen.add(key); items.push([ref.dataset.note, notes[key]]);
    }
    if (!items.length) continue;
    const scale = Number(frame.dataset.scale) || frame.getBoundingClientRect().width / Number(frame.dataset.width) || 1;
    let contentBottom = clip.top;
    for (const el of clipEl.querySelectorAll('x-p, table, img')) {
      for (const r of el.getClientRects()) if (inside(r)) contentBottom = Math.max(contentBottom, Math.min(r.bottom, clip.bottom));
    }
    const area = document.createElement('div'); area.className = 'docx-note-area';
    const left = parseFloat(clipEl.style.left) || 0, top0 = parseFloat(clipEl.style.top) || 0;
    const bodyHeight = parseFloat(clipEl.style.height) || 0, pageHeight = Number(frame.dataset.height);
    Object.assign(area.style, { left: `${left}px`, width: clipEl.style.width });
    for (const [label, text] of items) {
      const row = document.createElement('div'); row.className = 'docx-note';
      const mark = document.createElement('sup'); mark.textContent = label;
      row.append(mark, document.createTextNode(' ' + text)); area.appendChild(row);
    }
    source.appendChild(area);
    const h = area.getBoundingClientRect().height / scale;
    const usedBottom = top0 + (contentBottom - clip.top) / scale, bodyBottom = top0 + bodyHeight;
    let top = bodyBottom - h;
    if (top < usedBottom + 6) top = Math.min(bodyBottom + 4, pageHeight - h - 2);
    area.style.top = `${Math.max(0, top)}px`;
  }
}
// 지금 보이는 쪽(들)이 화면에서 차지하는 자리 (화면 크기 대비 0~1) — 스크롤 보기용 쪽 그림 자르기
// FReader: 두 쪽 보기의 홀수 마지막 쪽은 왼쪽에 놓고 오른쪽은 빈 자리(page-spacer)로 채움 → 실제 쪽만 셈
function realFrames() { return [...host.children].filter(f => f.classList.contains('page')); }
function pageRect() {
  const frames = realFrames(); if (!frames.length) return null;
  let l = 1e9, t = 1e9, r = -1e9, b = -1e9;
  const W = window.innerWidth || 1, H = window.innerHeight || 1, list = [], layout = [];
  for (const f of frames) {
    const q = f.getBoundingClientRect(); l = Math.min(l, q.left); t = Math.min(t, q.top); r = Math.max(r, q.right); b = Math.max(b, q.bottom);
    list.push({ x: q.left / W, y: q.top / H, w: q.width / W, h: q.height / H });
  }
  if (!(r > l && b > t)) return null;
  // 쪽 자리마다: 보이는 자리, 쪽 전체 자리(여백까지), 여백 줄이기 네모(쪽 대비), 빈 자리(두 쪽 보기의 홀수 마지막 쪽 옆)인지
  for (const f of host.children) {
    const q = f.getBoundingClientRect();
    let fit = null; try { fit = f.dataset.fit ? JSON.parse(f.dataset.fit) : null; } catch (_) {}
    const [tx, ty, pw, ph, bx, by, bw, bh] = fit || [0, 0, q.width, q.height, 0, 0, 1, 1];
    layout.push({ x: q.left / W, y: q.top / H, w: q.width / W, h: q.height / H, px: (q.left + tx) / W, py: (q.top + ty) / H, pw: pw / W, ph: ph / H, bx, by, bw, bh, real: f.classList.contains('page') });
  }
  return { x: Math.max(0, l / W), y: Math.max(0, t / H), w: Math.min(1, (r - l) / W), h: Math.min(1, (b - t) / H), frames: list, layout };
}
// FReader: 앱에서 고른 글에 형광펜 (화면 크기 대비 0~1 네모들)
function highlightBoxes(boxes) {
  const W = window.innerWidth || 1, H = window.innerHeight || 1;
  markRects((boxes || []).map(b => ({ left: b.x * W, top: b.y * H, width: b.w * W, height: b.h * H, right: (b.x + b.w) * W, bottom: (b.y + b.h) * H })));
}
// FReader: 모든 쪽의 크기 [너비, 높이] (스크롤 보기에서 쪽 자리를 먼저 잡아 두고 그림은 차례로 채움)
function pageSizes() { return pages.map(p => [Number(p.width) || 0, Number(p.height) || 0]); }
// FReader: 여백 줄이기 — 쪽 여백을 대부분 잘라 내고 본문을 화면에 크게 보여 줌 (글씨가 커지고 빈 곳이 줄어듦)
// 좌우 여백은 1/4, 위아래 여백은 머리말·꼬리말이 남도록 절반쯤 남김
const TRIM_KEEP_X = 0.25, TRIM_KEEP_Y = 0.55;
function trimBox(frame) {
  const W = Number(frame.dataset.width), H = Number(frame.dataset.height);
  let b = null; try { b = frame.dataset.box ? JSON.parse(frame.dataset.box) : null; } catch (_) {}
  if (!b || options.trimMargins === false || !(b.w > 16 && b.h > 16)) return { x: 0, y: 0, w: W, h: H };
  const x0 = b.x * (1 - TRIM_KEEP_X), x1 = W - Math.max(0, W - b.x - b.w) * (1 - TRIM_KEEP_X);
  const y0 = b.y * (1 - TRIM_KEEP_Y), y1 = H - Math.max(0, H - b.y - b.h) * (1 - TRIM_KEEP_Y);
  return { x: x0, y: y0, w: Math.max(16, x1 - x0), h: Math.max(16, y1 - y0) };
}
function fitPages() {
  const frames = [...host.children]; if (!frames.length) return;
  const boxes = frames.map(trimBox);
  const trimming = boxes.some((b, i) => b.w < Number(frames[i].dataset.width) - 0.5 || b.h < Number(frames[i].dataset.height) - 0.5);
  const pad = trimming ? 0.96 : 1; // 잘라 낸 쪽은 화면 끝에 딱 붙지 않게 살짝 띄움
  // 확대해 다시 그릴 때: 확대 전 화면 크기로 자리를 정한 뒤 모든 크기에 배율(Z)을 곱함 (CSS zoom을 쓰지 않아 기기 브라우저 버전에 따라 달라지지 않음)
  const Z = zoomView ? zoomDrawn : 1;
  const availW = (zoomView ? zoomBase[0] : host.clientWidth) - (8 / 3) * (frames.length - 1), availH = zoomView ? zoomBase[1] : host.clientHeight;
  const totalWidth = boxes.reduce((sum, b) => sum + b.w, 0);
  const height = Math.max(...boxes.map(b => b.h));
  const scale = Math.max(0.01, Math.min(availW * pad / totalWidth, availH * pad / height));
  frames.forEach((frame, i) => {
    const b = boxes[i], W = Number(frame.dataset.width), H = Number(frame.dataset.height);
    // 쪽 자리: 화면에서 이 쪽이 쓸 수 있는 만큼 (종이가 더 크면 그만큼 잘림)
    const slotW = Math.min(W * scale, availW * b.w / totalWidth), slotH = Math.min(H * scale, availH);
    const clamp = (v, lo) => Math.min(0, Math.max(lo, v));
    const tx = clamp((slotW - b.w * scale) / 2 - b.x * scale, slotW - W * scale);
    const ty = clamp((slotH - b.h * scale) / 2 - b.y * scale, slotH - H * scale);
    frame.style.width = `${slotW * Z}px`;
    frame.style.height = `${slotH * Z}px`;
    // 쪽 전체 자리·여백 줄이기 네모 (앱이 메모를 쪽에 붙이고, 화면을 돌릴 때 새 자리를 미리 계산하는 데 씀)
    frame.dataset.fit = JSON.stringify([tx, ty, W * scale, H * scale, b.x / W, b.y / H, b.w / W, b.h / H]);
    frame.dataset.scale = String(scale);
    if (frame.firstElementChild) frame.firstElementChild.style.transform = `translate(${tx * Z}px, ${ty * Z}px) scale(${scale * Z})`;
  });
}
// FReader: 쪽 뒤 바탕 = 문서 자체 배경색(있으면) > 앱 테마 색(흰색/검은색). 쪽 사이 간격 줄은 고정 색
function applyBackdrop() {
  const root = document.documentElement.style;
  const fileBg = options.docxLayout?.pageBackground;
  if (fileBg) root.setProperty('--file-page', fileBg); else root.removeProperty('--file-page');
  const backdrop = fileBg || options.backdrop;
  if (backdrop) root.setProperty('--backdrop', backdrop); else root.removeProperty('--backdrop');
}
function configure(next = {}) {
  const oldSpread = options.spread, oldTrim = options.trimMargins; options = { ...options, ...next };
  document.body.dataset.theme = ['white', 'sepia', 'dark'].includes(options.theme) ? options.theme : 'white';
  applyBackdrop();
  host.classList.toggle('rtl', !!options.rtl);
  if (docReady && pages.length && 'vertical' in next && !!next.vertical !== vertical) return setVertical(!!next.vertical);
  if (!docReady) return;
  if (vertical) {
    if (oldTrim !== options.trimMargins && vhost) { vLayout(true); vReportMetrics(); }
    return;
  }
  if (oldSpread !== options.spread) return render();
  fitPages();
}
async function display(position) {
  if (!pages.length) return;
  const saved = /^(?:docx|doc):(\d+)$/.exec(String(position));
  page = clampPage(saved ? Number(saved[1]) : Number(position));
  if (vertical) { vGoto(page); reportLocation(); return; }
  await render(); reportLocation();
}
function next() { if (vertical) return vScrollBy(1); return display(page + (options.spread ? 2 : 1)); }
function previous() { if (vertical) return vScrollBy(-1); return display(page - (options.spread ? 2 : 1)); }
function progress(value) { return display(Math.round(Math.max(0, Math.min(1, Number(value))) * (pages.length - 1))); }
function highlightSelection() {
  const selection = window.getSelection();
  if (!selection?.rangeCount || selection.isCollapsed) return;
  markRects([...selection.getRangeAt(0).getClientRects()]);
  selection.removeAllRanges();
}
function markRects(rects) {
  for (const frame of pageFrames()) {
    const bounds = frame.getBoundingClientRect();
    for (const rect of rects) {
      if (rect.width < 1 || rect.height < 1 || rect.left < bounds.left - 1 || rect.right > bounds.right + 1 || rect.top < bounds.top - 1 || rect.bottom > bounds.bottom + 1) continue;
      const mark = document.createElement('span');
      Object.assign(mark.style, { position: 'absolute', pointerEvents: 'none', background: '#ffc107', opacity: '.35', left: `${rect.left - bounds.left}px`, top: `${rect.top - bounds.top}px`, width: `${rect.width}px`, height: `${rect.height}px` });
      frame.appendChild(mark);
    }
  }
}
function destroy() {
  disposed = true; generation++; clearInterval(bridgeTimer); resizeObserver.disconnect();
  worker.terminate(); requests.forEach(resolve => resolve({ type: 'closed' })); requests.clear();
  if (incoming) incoming.fill(0); incoming = null; received = 0;
  clearPages(); pendingEvents = [];
}
let lastHostW = 0;
const resizeObserver = new ResizeObserver(() => {
  const w = host ? host.clientWidth : 0;
  if (typeof docxEditMode !== 'undefined' && docxEditMode && lastHostW > 0 && Math.abs(w - lastHostW) < 2) return;
  lastHostW = w;
  fitPages();
});
resizeObserver.observe(host);
// ── FReader: 스크롤 보기 — 쪽을 그대로 세로로 늘어놓고 쪽 사이를 살짝 띄움 (보이는 쪽 근처만 그림) ──
let vertical = false, vhost = null, vSlots = [], vTops = [], vRaf = 0, vMetricsTimer = 0, vSerial = 0;
const vMounted = new Map(); // 쪽 번호 → { frame, source, original, entry }
const vOwner = new Map(); // 원래 글 덩어리 → 그것을 쓰고 있는 쪽 번호 (다른 쪽은 복사본)
let blockInfo = new WeakMap(); // 원래 글 덩어리 → 맨 위 덩어리별 { first, last, top } (고치면 다시 잼)
function measureBlocks(source, inner, columns, columnStride) {
  try {
    const ir = inner.getBoundingClientRect(), k = ir.width / (inner.offsetWidth || ir.width || 1) || 1;
    if (!(k > 0) || !inner.isConnected) { blockInfo.delete(source); return; }
    const info = [];
    let prevLast = 0;
    for (const el of inner.children) {
      let first = Infinity, last = -1, top = 0, bottom = 0;
      for (const r of el.getClientRects()) {
        if (!(r.width > 0 || r.height > 0)) continue;
        const c = Math.max(0, Math.min(columns - 1, Math.floor(((r.left - ir.left) / k + 0.5) / columnStride)));
        const t = (r.top - ir.top) / k, b = (r.bottom - ir.top) / k;
        if (c < first) { first = c; top = t; bottom = b; } else if (c === first) { top = Math.min(top, t); bottom = Math.max(bottom, b); }
        if (c > last) last = c;
      }
      if (last < 0) { first = prevLast; last = prevLast; top = -1; bottom = -1; }
      // h: 시작 칸에서 차지한 높이 (다음 쪽으로 이어지는 덩어리를 복사본에서도 같은 줄에서 끊으려고)
      info.push({ first, last, top, h: Math.max(0, bottom - top) });
      prevLast = last;
    }
    info.colH = inner.clientHeight;
    blockInfo.set(source, info);
  } catch (_) { blockInfo.delete(source); }
}
let vOriginalPage = null; // 원래 글 덩어리를 써야 하는 쪽 (찾은 낱말 형광펜·편집)
/** 스크롤 보기용 쪽 복사본: 그 쪽에 걸친 맨 위 덩어리만 담고, 앞 덩어리 자리는 빈 칸으로 채워 같은 자리에 놓음 */
function vMakeClone(entry, index) {
  // 복사본의 그림 주소는 원래 글에 남아 있던 것(이미 지운 주소일 수 있음)이라 비우고, 붙인 뒤 새로 채움 (깨진 그림 표시 방지)
  const made = vMakeCloneRaw(entry, index);
  for (const img of made.querySelectorAll('img[data-resource][src]')) img.removeAttribute('src');
  return made;
}
function vMakeCloneRaw(entry, index) {
  const src = entry.source, info = blockInfo.get(src);
  const inner = src.querySelector('.freader-columns');
  if (!info || !inner || info.length !== inner.children.length) return src.cloneNode(true);
  const c = entry.column, keep = [];
  info.forEach((b, i) => { if (b.first <= c && b.last >= c) keep.push(i); });
  if (!keep.length) return src.cloneNode(true);
  const head = info[keep[0]];
  // 앞쪽에서 두 쪽 넘게 이어 온 덩어리(아주 긴 표 등)는 끊기는 자리를 맞추기 어려우므로 구역 전체를 복사
  if (head.first < c - 1 || !(info.colH > 0)) return src.cloneNode(true);
  // 앞 쪽에서 이어지는 덩어리: 앞 칸에 원래와 같은 높이만큼만 들어가도록 빈 칸 높이를 정함 (줄 끊김을 원래와 똑같이)
  const spacerH = head.first < c ? Math.max(0, info.colH - head.h - 0.5) : head.top;
  const fresh = src.cloneNode(false);
  for (const child of src.children) {
    if (!child.classList.contains('freader-content')) { fresh.appendChild(child.cloneNode(true)); continue; }
    const clip = child.cloneNode(false);
    const box = inner.cloneNode(false);
    const startCol = head.first;
    if (spacerH > 0.5) {
      const spacer = document.createElement('div');
      spacer.className = 'freader-vspacer';
      spacer.style.cssText = `height:${spacerH}px;margin:0;padding:0;break-inside:avoid;break-after:auto`;
      box.appendChild(spacer);
    }
    keep.forEach((i, n) => {
      const el = inner.children[i].cloneNode(true);
      if (n === 0) {
        el.style.marginTop = '0px'; el.style.breakBefore = 'auto';
        if (head.first < c) { el.style.orphans = '1'; el.style.widows = '1'; }
      }
      box.appendChild(el);
    });
    clip.appendChild(box);
    for (const rest of [...child.children].slice(1)) clip.appendChild(rest.cloneNode(true));
    fresh.appendChild(clip);
    fresh.dataset.vcol = String(c - startCol);
  }
  return fresh;
}
const V_GAP = 6; // 스크롤 보기 쪽 사이 간격 (예전 12의 절반)
function pageFrames() { return vertical ? [...vMounted.values()].map(m => m.frame) : realFrames(); }
let lastVHostW = 0;
const vResize = new ResizeObserver(() => {
  if (!vertical || !vhost) return;
  const w = vhost.clientWidth;
  if (typeof docxEditMode !== 'undefined' && docxEditMode && lastVHostW > 0 && Math.abs(w - lastVHostW) < 2) return;
  lastVHostW = w;
  vLayout(true);
});
function setVertical(on) {
  on = !!on;
  if (on === vertical) return;
  if (on) {
    vertical = true;
    renderSerial++;
    for (const frame of host.children) {
      for (const img of frame.querySelectorAll('img[data-resource]')) img.removeAttribute('src');
      const source = frame.firstElementChild;
      if (originalSources.has(source)) measure.appendChild(source);
    }
    host.replaceChildren(); host.style.display = 'none';
    vhost = document.createElement('div'); vhost.id = 'vpages';
    vinner = document.createElement('div'); vinner.id = 'vinner'; vhost.appendChild(vinner);
    document.body.appendChild(vhost);
    vhost.addEventListener('scroll', vSchedule, { passive: true });
    vResize.observe(vhost);
    vZoomListen(vhost);
    vLayout(false);
    vGoto(page);
  } else {
    vertical = false;
    vResize.disconnect();
    for (const index of [...vMounted.keys()]) vUnmount(index);
    vhost?.remove(); vhost = null; vinner = null; vSlots = []; vTops = []; vRatios = []; vZoom = 1; vPinch = null;
    host.style.display = '';
    void render().then(reportLocation);
  }
}
// ── FReader: 스크롤 보기 두 손가락 확대·축소 (줄이면 쪽이 작아져 가운데에, 늘리면 옆으로도 움직일 수 있음) ──
let vZoom = 1, vPinch = null, vinner = null;
const V_ZOOM_MIN = 0.5, V_ZOOM_MAX = 3;
function vTouchInfo(t) {
  return { d: Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY), x: (t[0].clientX + t[1].clientX) / 2, y: (t[0].clientY + t[1].clientY) / 2 };
}
function vPinchStart(e) {
  if (!vertical || !vhost || e.touches.length !== 2 || !vTops.length) return;
  if (docxEditMode) document.body.classList.add('eri-scrolling');
  const t = vTouchInfo(e.touches);
  // 손가락 가운데에 있던 글 자리 (몇째 쪽의 어느 비율 자리인지) — 크기를 바꿔도 그 글이 손가락 아래 남게
  const cy = vhost.scrollTop + t.y, cx = vhost.scrollLeft + t.x, i = vIndexAt(cy);
  const sh = Math.max(1, vTops[i + 1] - vTops[i] - V_GAP), sw = Math.max(1, vPageWidth());
  vPinch = { d0: Math.max(1, t.d), z0: vZoom, z: vZoom, i, fy: (cy - vTops[i]) / sh, fx: (cx - vLeft()) / sw, cx, cy, x: t.x, y: t.y, raf: 0 };
  // 줄이면 화면에 들어올 위아래 쪽을 미리 붙여 둠 (줄이는 동안 빈 곳이 보이지 않게)
  const r = V_ZOOM_MIN / vZoom, H = vhost.clientHeight || innerHeight;
  vMountRange(vIndexAt(cy - t.y / r), vIndexAt(cy + (H - t.y) / r));
  e.preventDefault();
}
function vPinchMove(e) {
  if (!vPinch || !vhost) return;
  e.preventDefault();
  if (e.touches.length !== 2) return;
  const t = vTouchInfo(e.touches);
  vPinch.z = Math.max(V_ZOOM_MIN, Math.min(V_ZOOM_MAX, vPinch.z0 * t.d / vPinch.d0));
  vPinch.x = t.x; vPinch.y = t.y;
  if (!vPinch.raf) vPinch.raf = requestAnimationFrame(vPinchFrame);
}
// 손가락이 움직이는 동안: 이미 그려 둔 쪽들을 통째로 옮기고 크기만 바꿈 (다시 그리지 않아 빠르고 빈 곳이 없음)
function vPinchFrame() {
  const p = vPinch; if (!p || !vinner) return;
  p.raf = 0;
  const r = p.z / p.z0;
  const tx = p.x + vhost.scrollLeft - p.cx * r, ty = p.y + vhost.scrollTop - p.cy * r;
  vinner.style.transform = `translate(${tx}px, ${ty}px) scale(${r})`;
  // 줄이고 늘리는 동안에도 쪽 자리를 앱에 알림 (고른 글 바탕이 글과 함께 움직이게)
  vReportMetrics();
}
function vPinchEnd(e) {
  if (!vPinch || !vhost) return;
  if (e.touches.length >= 2) return;
  const p = vPinch;
  if (p.raf) { cancelAnimationFrame(p.raf); p.raf = 0; }
  vPinch = null;
  // 거의 원래 크기면 딱 원래 크기로
  if (Math.abs(p.z - 1) < 0.05) p.z = 1;
  // 손가락을 떼면 그 크기로 다시 놓고 다시 그림 (또렷하게), 손가락 아래 글은 그대로
  vZoom = p.z;
  vSize();
  vinner.style.transform = '';
  const sh = Math.max(1, vTops[p.i + 1] - vTops[p.i] - V_GAP);
  vhost.scrollTop = vTops[p.i] + p.fy * sh - p.y;
  vhost.scrollLeft = vLeft() + p.fx * vPageWidth() - p.x;
  if (docxEditMode) { if (docxSelRange && !docxSelRange.collapsed) docxRenderSelection(); else if (docxCursor) docxRenderCaret(); if (docxScrollHideTimer) clearTimeout(docxScrollHideTimer); docxScrollHideTimer = setTimeout(() => { docxScrollHideTimer = 0; document.body.classList.remove('eri-scrolling'); }, 180); }
  vUpdate();
  vReportMetrics();
}
/** [a, b] 쪽을 한꺼번에 붙임 (두 손가락으로 줄이기 전에) */
function vMountRange(a, b) {
  for (let i = Math.max(0, a - 1); i <= Math.min(vSlots.length - 1, b + 1); i++) {
    if (!vMounted.has(i)) { try { vMount(i); } catch (error) { console.warn(error); } }
  }
}
// FReader: 스크롤 보기 북마크 — 북마크한 쪽 왼쪽 위에 책갈피 (쪽과 함께 움직이고 확대·축소돼도 보임)
let vMarks = new Set();
function vApplyMarks() { vSlots.forEach((slot, i) => slot.classList.toggle('bm', vMarks.has(i))); }
function setScrollMarks(pages) { vMarks = new Set((pages || []).map(Number)); vApplyMarks(); return true; }

// FReader: 스크롤 보기 메모 — 넘겨 보기와 같은 쪽 메모(쪽 전체 크기 대비 0~1 자리)를 쪽 위에 그려 쪽과 함께 움직이고 확대·축소됨
let vMemos = {}; // 쪽 번호 → [{ x: [..], y: [..], c: ARGB, w: 쪽 너비 대비 굵기 }]
function vArgb(c) { c = Number(c) >>> 0; return `rgba(${(c >>> 16) & 255},${(c >>> 8) & 255},${c & 255},${((c >>> 24) & 255) / 255})`; }
function vDrawMemo(i) {
  const slot = vFull(i); if (!slot) return;
  let svg = slot.querySelector(':scope > svg.vmemo');
  const list = vMemos[i];
  if (!list || !list.length) { svg?.remove(); return; }
  const r = vRatios[i] || 1.414, H = 1000 * r;
  if (!svg) {
    svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', 'vmemo'); svg.setAttribute('preserveAspectRatio', 'none');
    slot.appendChild(svg);
  }
  svg.setAttribute('viewBox', `0 0 1000 ${H}`);
  const renderOne = (s) => {
    const xs = s.x || [], ys = s.y || [];
    if (!xs.length) return '';
    const w = Math.max(0.5, (Number(s.w) || 0.004) * 1000);
    const col = vArgb(s.c);
    const kind = s.k || 'pen';
    if (kind === 'tape') {
      const pts = [];
      const minStep = Math.max(5, w * 0.22);
      for (let k = 0; k < xs.length; k++) {
        const px = xs[k] * 1000, py = ys[k] * H;
        if (!pts.length || Math.hypot(px - pts[pts.length - 1][0], py - pts[pts.length - 1][1]) >= minStep) {
          pts.push([px, py]);
        }
      }
      if (xs.length >= 2) {
        const lx = xs[xs.length - 1] * 1000, ly = ys[ys.length - 1] * H;
        if (Math.hypot(lx - pts[pts.length - 1][0], ly - pts[pts.length - 1][1]) >= 1.5) pts.push([lx, ly]);
      }
      const endSafe = Math.max(w * 0.95, 18);
      while (pts.length >= 3 && Math.hypot(pts[pts.length - 1][0] - pts[pts.length - 2][0], pts[pts.length - 1][1] - pts[pts.length - 2][1]) < endSafe) {
        const a = pts[pts.length - 3], b = pts[pts.length - 2], c = pts[pts.length - 1];
        if ((b[0] - a[0]) * (c[0] - b[0]) + (b[1] - a[1]) * (c[1] - b[1]) < 0) pts.pop();
        else pts.splice(pts.length - 2, 1);
      }
      while (pts.length >= 3 && Math.hypot(pts[1][0] - pts[0][0], pts[1][1] - pts[0][1]) < endSafe) {
        const a = pts[0], b = pts[1], c = pts[2];
        if ((b[0] - a[0]) * (c[0] - b[0]) + (b[1] - a[1]) * (c[1] - b[1]) < 0) pts.shift();
        else pts.splice(1, 1);
      }
      if (!pts.length) return '';
      if (pts.length === 1) {
        const [x0, y0] = pts[0];
        pts.push([x0 + 0.5, y0]);
      }
      const first = pts[0], last = pts[pts.length - 1];
      let d = `M${first[0].toFixed(1)} ${first[1].toFixed(1)}`;
      for (let k = 1; k < pts.length; k++) d += ` L${pts[k][0].toFixed(1)} ${pts[k][1].toFixed(1)}`;
      const dirAt = (start) => {
        const n = pts.length, base = start ? first : last;
        const step = start ? 1 : -1;
        for (let idx = start ? 1 : n - 2; idx >= 0 && idx < n; idx += step) {
          const dx = base[0] - pts[idx][0], dy = base[1] - pts[idx][1];
          const dist = Math.hypot(dx, dy);
          if (dist > 0.01) return [dx / dist, dy / dist];
        }
        return start ? [-1, 0] : [1, 0];
      };
      const teethPath = (p, dir) => {
        const nx = -dir[1], ny = dir[0];
        const half = w / 2;
        const cnt = Math.max(3, Math.round(w / 14));
        const depth = Math.min(w * 0.24, 14);
        const overlap = Math.max(2.5, w * 0.12);
        const bx = p[0] - dir[0] * overlap, by = p[1] - dir[1] * overlap;
        let td = `M${(bx + nx * half).toFixed(1)} ${(by + ny * half).toFixed(1)}`;
        td += ` L${(p[0] + nx * half).toFixed(1)} ${(p[1] + ny * half).toFixed(1)}`;
        for (let j = 0; j < cnt; j++) {
          const a0 = half - (2 * half) * j / cnt;
          const mid = a0 - half / cnt;
          const pkx = p[0] + dir[0] * depth + nx * mid;
          const pky = p[1] + dir[1] * depth + ny * mid;
          const vOff = a0 - 2 * half / cnt;
          const vlx = p[0] + nx * vOff;
          const vly = p[1] + ny * vOff;
          td += ` L${pkx.toFixed(1)} ${pky.toFixed(1)} L${vlx.toFixed(1)} ${vly.toFixed(1)}`;
        }
        td += ` L${(bx - nx * half).toFixed(1)} ${(by - ny * half).toFixed(1)} Z`;
        return td;
      };
      const t1 = teethPath(first, dirAt(true));
      const t2 = teethPath(last, dirAt(false));
      const opaqueCol = `rgb(${(Number(s.c) >>> 16) & 255},${(Number(s.c) >>> 8) & 255},${Number(s.c) & 255})`;
      const inner = `<path d="${d}" fill="none" stroke="${opaqueCol}" stroke-width="${w.toFixed(2)}" stroke-linecap="butt" stroke-linejoin="round"/><path d="${t1}" fill="${opaqueCol}"/><path d="${t2}" fill="${opaqueCol}"/>`;
      return s.th ? `<g opacity="0.3">${inner}</g>` : inner;
    }
    let d = `M${(xs[0] * 1000).toFixed(1)} ${(ys[0] * H).toFixed(1)}`;
    if (xs.length === 1) d += ` L${(xs[0] * 1000 + 0.1).toFixed(1)} ${(ys[0] * H).toFixed(1)}`;
    for (let k = 1; k < xs.length; k++) d += ` L${(xs[k] * 1000).toFixed(1)} ${(ys[k] * H).toFixed(1)}`;
    const cap = kind === 'hl' ? 'square' : 'round';
    return `<path d="${d}" fill="none" stroke="${col}" stroke-width="${w.toFixed(2)}" stroke-linecap="${cap}" stroke-linejoin="round"/>`;
  };
  const hls = list.filter(s => s.k === 'hl').map(renderOne);
  const others = list.filter(s => s.k !== 'hl').map(renderOne);
  svg.innerHTML = hls.concat(others).join('');
}
function vApplyMemos() { for (let i = 0; i < vSlots.length; i++) vDrawMemo(i); }
/** 모든 쪽 메모를 한꺼번에 ({쪽: 획들}) */
function setScrollMemos(all) { vMemos = all || {}; vApplyMemos(); return true; }
/** 한 쪽 메모만 바꿈 (쓰거나 지운 뒤) */
function setScrollMemo(index, strokes) {
  index = Number(index);
  if (strokes && strokes.length) vMemos[index] = strokes; else delete vMemos[index];
  vDrawMemo(index);
  return true;
}
/** 화면에 보이는 쪽들의 자리 (화면 크기 대비 0~1): 메모를 쓸 때 쪽 안 자리로 바꾸는 데 씀 */
function vVisibleSlots() {
  if (!vertical || !vhost || !vTops.length) return [];
  const W = window.innerWidth || 1, H = window.innerHeight || 1, st = vhost.scrollTop, VH = vhost.clientHeight || H;
  const out = [];
  for (let i = Math.max(0, vIndexAt(st) - 1); i < vSlots.length && vTops[i] < st + VH; i++) {
    const v = vSlots[i].getBoundingClientRect();
    if (v.bottom < 0 || v.top > H) continue;
    const q = vFull(i).getBoundingClientRect(); // 쪽 전체(여백 줄이기로 가린 여백까지) — 메모는 늘 쪽 전체 기준
    out.push({ page: i, left: q.left / W, top: q.top / H, width: q.width / W, height: q.height / H,
      vleft: v.left / W, vtop: v.top / H, vwidth: v.width / W, vheight: v.height / H });
  }
  return out;
}
// 화면에 가장 많이(비율로) 보이는 쪽 (스크롤 보기에서 북마크할 쪽)
function vMostVisible() {
  if (!vertical || !vhost || !vSlots.length) return page;
  const y0 = vhost.scrollTop, y1 = y0 + vhost.clientHeight;
  let best = page, bestF = -1;
  for (let i = Math.max(0, vIndexAt(y0) - 1); i < vSlots.length && vTops[i] < y1; i++) {
    const h = Math.max(1, vTops[i + 1] - vTops[i] - V_GAP);
    const f = (Math.min(vTops[i] + h, y1) - Math.max(vTops[i], y0)) / h;
    if (f > bestF + 0.001) { bestF = f; best = i; }
  }
  return best;
}
// FReader: 스크롤 보기에서 확대·축소해 둔 것을 원래 크기로 (화면 가운데 있던 글 자리를 그대로 두고)
function vResetZoom() {
  if (!vertical || !vhost || vZoom === 1) return false;
  const fyScreen = (vhost.clientHeight || innerHeight) / 2, fxScreen = (vhost.clientWidth || innerWidth) / 2;
  const cy = vhost.scrollTop + fyScreen, i = vIndexAt(cy), slot = vSlots[i];
  const sh = Math.max(1, slot ? slot.offsetHeight : 1), sw = Math.max(1, slot ? slot.offsetWidth : 1);
  const fy = (cy - vTops[i]) / sh, fx = (vhost.scrollLeft + fxScreen - (slot ? slot.offsetLeft : 0)) / sw;
  vZoom = 1;
  vLayout(true);
  const s2 = vSlots[i];
  if (s2) {
    vhost.scrollTop = vTops[i] + fy * s2.offsetHeight - fyScreen;
    vhost.scrollLeft = s2.offsetLeft + fx * s2.offsetWidth - fxScreen;
  }
  vUpdate(); vReportMetrics();
  return true;
}
function vZoomListen(el) {
  el.addEventListener('touchstart', vPinchStart, { passive: false });
  el.addEventListener('touchmove', vPinchMove, { passive: false });
  el.addEventListener('touchend', vPinchEnd);
  el.addEventListener('touchcancel', vPinchEnd);
}
/** 확대 배율에 맞춘 쪽 너비 */
function vPageWidth() { return (innerWidth || vhost.clientWidth) * vZoom; }
/** 화면보다 좁게 줄였으면 쪽을 가로 가운데에 (쪽 왼쪽 끝 자리) */
function vLeft() {
  const VW = innerWidth || vhost.clientWidth, W = vPageWidth();
  return W < VW - 0.5 ? Math.floor((VW - W) / 2) : 0;
}
// 쪽 크기는 쪽마다 정해 둔 비율 × 쪽 너비(--vw) — 확대·축소할 때는 너비 하나만 바꾸면 모든 쪽이 따라 바뀜
let vRatios = [];
function vSetRatio(i, r) {
  if (vRatios[i] === r) return;
  vRatios[i] = r;
  vSlots[i].style.height = `calc(var(--vw) * ${vVisRatio(i)})`;
  if (vMemos[i]) vDrawMemo(i);
}
// ── FReader: 여백 줄이기 (스크롤 보기) — 쪽 칸은 보이는 자리(여백을 잘라 낸 본문)만큼, 쪽 전체(.vfull)는 그 안에서 여백만큼 밀려 놓임
// 메모·고른 글 바탕·화면 좌표는 모두 쪽 전체 기준이라 여백 줄이기를 켜고 꺼도 자리가 그대로임
let vTrim = [];
function vFull(i) { return vSlots[i]?.firstElementChild || vSlots[i] || null; }
function vTrimFor(i) {
  const e = pages[i];
  if (options.trimMargins !== true || !e || !e.box) return null;
  const W = Number(e.width), H = Number(e.height), b = e.box;
  if (!(W > 0 && H > 0 && b.w > 16 && b.h > 16)) return null;
  const x0 = b.x * (1 - TRIM_KEEP_X), x1 = W - Math.max(0, W - b.x - b.w) * (1 - TRIM_KEEP_X);
  const y0 = b.y * (1 - TRIM_KEEP_Y), y1 = H - Math.max(0, H - b.y - b.h) * (1 - TRIM_KEEP_Y);
  return { x: x0 / W, y: y0 / H, w: Math.max(0.1, (x1 - x0) / W), h: Math.max(0.1, (y1 - y0) / H) };
}
function vVisRatio(i) { const t = vTrim[i], r = vRatios[i] || 1.414; return t ? r * t.h / t.w * TRIM_PAD : r; }
// 여백 줄이기: 쪽 넘김 보기처럼 잘라 낸 본문이 화면 끝에 딱 붙지 않게 양옆을 2%씩 띄움 (두 보기의 크기 비율을 같게)
const TRIM_PAD = 0.96;
function vSlotWidthCss(i) { return vTrim[i] ? `calc(var(--vw) * ${TRIM_PAD})` : ''; }
function vSlotLeftCss(i) { return vTrim[i] ? `calc(var(--vml, 0px) + var(--vw) * ${(1 - TRIM_PAD) / 2})` : ''; }
/** 쪽 전체가 화면에서 쓰는 너비 (여백 줄이기면 본문이 화면 너비를 채우도록 더 넓음) */
function vFullWidth(i) { const t = vTrim[i]; return t ? vPageWidth() * TRIM_PAD / t.w : vPageWidth(); }
function vApplyTrim() {
  vTrim = pages.map((_, i) => vTrimFor(i));
  vSlots.forEach((slot, i) => {
    let full = slot.firstElementChild;
    if (!full || !full.classList.contains('vfull')) { full = document.createElement('div'); full.className = 'vfull'; slot.prepend(full); }
    const t = vTrim[i];
    Object.assign(full.style, t
      ? { left: `${-t.x / t.w * 100}%`, top: `${-t.y / t.h * 100}%`, width: `${100 / t.w}%`, height: `${100 / t.h}%` }
      : { left: '0', top: '0', width: '100%', height: '100%' });
    slot.style.width = vSlotWidthCss(i);
    slot.style.marginLeft = vSlotLeftCss(i);
    if (vRatios[i]) slot.style.height = `calc(var(--vw) * ${vVisRatio(i)})`;
  });
}
/** 지금 배율로 쪽 너비·자리를 다시 셈 (쪽을 다시 그리지 않음) */
function vSize() {
  const W = vPageWidth();
  vhost.style.setProperty('--vw', `${W}px`);
  vhost.style.setProperty('--vml', `${vLeft()}px`);
  vhost.style.overflowX = vZoom > 1.001 ? 'auto' : 'hidden';
  vTops = []; let y = 0;
  for (let i = 0; i < vRatios.length; i++) { vTops.push(y); y += W * vVisRatio(i) + V_GAP; }
  vTops.push(y);
  // 쪽이 화면보다 짧으면(1쪽뿐인 문서 등) 위에 붙이지 않고 화면 가운데에
  const total = y - V_GAP, viewH = innerHeight || vhost.clientHeight;
  const pad = total < viewH ? Math.floor((viewH - total) / 2) : 0;
  if (vSlots.length) {
    vSlots[0].style.marginTop = pad ? `${pad}px` : '';
    vSlots[vSlots.length - 1].style.marginBottom = pad ? '0px' : '';
  }
  if (pad) for (let i = 0; i < vTops.length; i++) vTops[i] += pad;
  for (const [i, m] of vMounted) m.source.style.transform = `scale(${vFullWidth(i) / m.entry.width})`;
  if (docxEditMode) { if (docxSelRange && !docxSelRange.collapsed) docxRenderSelection(); else if (docxCursor) docxRenderCaret(); }
}
// 길게 눌러 고른 글 바탕 (스크롤 보기): 앱이 [쪽, 왼쪽, 위, 너비, 높이](쪽 크기 대비 0~1)로 보내 주면
// 쪽 칸 안에 붙여 그림 → 스크롤·확대·축소 중에도 글과 한 몸으로 움직임 (앱 위에 그리면 한 박자 늦게 따라와 어긋났음)
let copyMarks = [];
const copyMarkEls = new Map(); // 쪽 칸 → 그 안의 바탕 네모들
function vApplyCopyMarks() {
  const bySlot = new Map();
  if (vertical) {
    for (const q of copyMarks) {
      const slot = vFull(q[0]);
      if (!slot) continue;
      if (!bySlot.has(slot)) bySlot.set(slot, []);
      bySlot.get(slot).push(q);
    }
  }
  for (const [slot, els] of copyMarkEls) {
    if (bySlot.has(slot) && slot.isConnected) continue;
    for (const el of els) el.remove();
    copyMarkEls.delete(slot);
  }
  for (const [slot, qs] of bySlot) {
    const els = copyMarkEls.get(slot) || [];
    while (els.length > qs.length) els.pop().remove();
    qs.forEach((q, i) => {
      let el = els[i];
      if (!el) { el = document.createElement('div'); el.className = 'eri-copy-mark'; slot.appendChild(el); els.push(el); }
      el.style.left = `${q[1] * 100}%`; el.style.top = `${q[2] * 100}%`;
      el.style.width = `${q[3] * 100}%`; el.style.height = `${q[4] * 100}%`;
    });
    copyMarkEls.set(slot, els);
  }
}
function setCopyMarks(list) {
  copyMarks = Array.isArray(list) ? list.filter(q => Array.isArray(q) && q.length >= 5) : [];
  vApplyCopyMarks();
  return true;
}
function vLayout(keep) {
  if (!vhost || !pages.length) return;
  let anchor = page, frac = 0;
  if (keep && vTops.length) {
    const st = vhost.scrollTop;
    anchor = vIndexAt(st);
    frac = (st - vTops[anchor]) / Math.max(1, vTops[anchor + 1] - vTops[anchor]);
  }
  for (const index of [...vMounted.keys()]) vUnmount(index);
  if (vSlots.length !== pages.length) {
    vinner.replaceChildren();
    vSlots = []; vRatios = [];
    for (let i = 0; i < pages.length; i++) {
      const slot = document.createElement('div'); slot.className = 'vslot'; slot.dataset.page = String(i);
      vinner.appendChild(slot); vSlots.push(slot);
    }
  }
  vRatios.length = 0;
  pages.forEach((entry, i) => { vRatios[i] = entry.width > 0 ? entry.height / entry.width : 1.414; });
  vApplyTrim();
  vApplyMarks();
  vApplyCopyMarks();
  pages.forEach((entry, i) => vSetRatio(i, entry.width > 0 ? entry.height / entry.width : 1.414));
  vRatios.length = pages.length;
  vSize();
  vApplyMemos();
  vhost.scrollTop = vTops[anchor] + frac * (vTops[anchor + 1] - vTops[anchor]);
  vUpdate();
}
function vIndexAt(y) {
  let lo = 0, hi = pages.length - 1;
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (vTops[mid] <= y) lo = mid; else hi = mid - 1; }
  return lo;
}
function vGoto(index) {
  if (!vhost || !vTops.length) return;
  vhost.scrollTop = vTops[clampPage(index)];
  vUpdate();
}
function vScrollBy(dir) { vhost?.scrollBy({ top: dir * (innerHeight || vhost.clientHeight) * 0.9, behavior: 'smooth' }); }
function vScrollToRatio(t) {
  if (!vhost) return;
  vhost.scrollTop = Math.max(0, Math.min(1, Number(t) || 0)) * Math.max(0, vhost.scrollHeight - vhost.clientHeight);
}
let docxScrollHideTimer = 0;
function markDocxScrolling() {
  if (!docxEditMode || docxActiveHandleSide || docxCaretHandleDragging) return;
  document.body.classList.add('eri-scrolling');
  if (docxScrollHideTimer) clearTimeout(docxScrollHideTimer);
  docxScrollHideTimer = setTimeout(() => {
    docxScrollHideTimer = 0;
    document.body.classList.remove('eri-scrolling');
  }, 180);
}
function vSchedule() {
  markDocxScrolling();
  if (!vRaf) vRaf = requestAnimationFrame(() => { vRaf = 0; vUpdate(); vReportMetrics(); });
}
/** 화면 가까이 있는 쪽들의 화면 자리 [쪽, 왼쪽, 위, 너비, 높이] (화면 크기 대비 0~1) —
 * 앱이 길게 눌러 고른 글 바탕을 쪽에 붙여 그리는 데 씀 (스크롤·확대·축소·두 손가락으로 줄이는 중에도 글과 딱 맞게) */
function vSlotGeom() {
  if (!vertical || !vhost || !vTops.length || !vSlots.length) return [];
  const W = innerWidth || 1, H = innerHeight || 1, out = [];
  const at = vIndexAt(vhost.scrollTop + (vhost.clientHeight || H) / 2);
  const push = (i) => {
    const q = vFull(i).getBoundingClientRect();
    out.push([i, q.left / W, q.top / H, q.width / W, q.height / H]);
    return vSlots[i].getBoundingClientRect();
  };
  push(at);
  // 화면 밖으로 한 쪽 더 나갈 때까지 위·아래로 (줄이는 중이면 여러 쪽이 보임)
  for (let i = at - 1, n = 0; i >= 0 && n < 40; i--, n++) { if (push(i).bottom < -H * 0.5) break; }
  for (let i = at + 1, n = 0; i < vSlots.length && n < 40; i++, n++) { if (push(i).top > H * 1.5) break; }
  return out;
}
function vReportMetrics() {
  if (vhost) emit('scrollMetrics', { top: vhost.scrollTop, height: vhost.scrollHeight, client: vhost.clientHeight, zoom: vZoom, slots: vSlotGeom() });
}
function vMount(index) {
  if (vMounted.has(index) || !pages[index]) return;
  const entry = pages[index];
  // 원래 글 덩어리는 정해 둔 쪽(찾은 낱말·편집)만 씀 — 원래 덩어리를 옮기면 구역 전체를 다시 배치해 느림
  const original = index === vOriginalPage && !vOwner.has(entry.source);
  const source = original ? entry.source : vMakeClone(entry, index);
  if (original) vOwner.set(entry.source, index);
  preparePageSource(source, entry, index);
  const slot = vFull(index), scale = vFullWidth(index) / entry.width;
  const frame = document.createElement('section');
  frame.className = 'page'; frame.dataset.page = String(index);
  frame.dataset.width = String(entry.width); frame.dataset.height = String(entry.height);
  frame.style.width = '100%'; frame.style.height = '100%';
  source.style.transform = `scale(${scale})`;
  frame.appendChild(source); slot.appendChild(frame);
  vMounted.set(index, { frame, source, original, entry });
  renderNoteAreas([frame]);
  void vLoadImages(frame, vSerial);
}
function vUnmount(index) {
  const m = vMounted.get(index); if (!m) return;
  for (const img of m.frame.querySelectorAll('img[data-resource]')) img.removeAttribute('src');
  if (m.original) { measure.appendChild(m.source); vOwner.delete(m.entry.source); }
  m.frame.remove(); vMounted.delete(index);
}
/** 이 쪽이 원래 글 덩어리를 쓰게 (찾은 낱말 형광펜은 원래 글에만 칠해짐) */
function vEnsureOriginal(index) {
  vOriginalPage = index;
  const m = vMounted.get(index); if (!m || m.original) return;
  const owner = vOwner.get(m.entry.source);
  if (owner != null) vUnmount(owner);
  vUnmount(index); vMount(index);
  if (owner != null) vMount(owner);
}
/**
 * 편집용: 이 쪽이 원래 글 덩어리를 쓰게 함 (스크롤 보기에서 같은 구역의 다른 쪽은 복사본이라 거기에 고친 글은 저장되지 않음).
 * 다시 그리지 않고 원래 덩어리와 복사본 자리만 맞바꿔서 그림이 깜빡이지 않게 함
 */
function vAdoptOriginal(index) {
  const m = vMounted.get(index); if (!m || m.original) return false;
  const orig = m.entry.source, clone = m.source;
  const ownerIdx = vOwner.get(orig);
  const o = ownerIdx != null ? vMounted.get(ownerIdx) : null;
  vOriginalPage = index;
  if (o && o.source === orig) {
    const other = vMakeClone(o.entry, ownerIdx);
    orig.replaceWith(other);
    o.source = other; o.original = false;
    void vLoadImages(o.frame, vSerial);
  }
  clone.replaceWith(orig);
  m.source = orig; m.original = true; vOwner.set(orig, index);
  void vLoadImages(m.frame, vSerial);
  for (const [i, mm] of [[index, m], [ownerIdx, o]]) {
    if (!mm) continue;
    preparePageSource(mm.source, mm.entry, i);
    mm.source.style.transform = `scale(${vFullWidth(i) / mm.entry.width})`;
  }
  return true;
}
/** 편집으로 원래 글이 바뀐 뒤: 같은 구역을 보여 주는 복사본 쪽을 새로 복사 (넘친 줄이 다음 쪽에 바로 보이게) */
function vRefreshClones() {
  if (!vertical || !vhost) return;
  for (const [i, m] of vMounted) {
    if (pages[i]) m.entry = pages[i];
    if (m.original || !vOwner.has(m.entry.source)) continue;
    const fresh = vMakeClone(m.entry, i);
    for (const el of fresh.querySelectorAll('.eri-docx-caret, .eri-caret-handle, .eri-sel-handle, .eri-docx-sel-rect')) el.remove();
    preparePageSource(fresh, m.entry, i);
    fresh.style.transform = `scale(${vFullWidth(i) / m.entry.width})`;
    m.source.replaceWith(fresh); m.source = fresh;
    void vLoadImages(m.frame, vSerial);
  }
}
async function vLoadImages(frame, serial) {
  // 구역 전체가 든 쪽이면 그 쪽 그림 목록에 있는 것만 자리를 재 봄 (그림이 수백 장이면 전부 재는 것도 무거움)
  const entry = pages[Number(frame.dataset.page)];
  const full = !frame.querySelector('.freader-vspacer') && frame.querySelector('.freader-columns')?.children.length > 40;
  const want = full && entry?.images ? new Set(entry.images) : null;
  const imgs = [...frame.querySelectorAll('img[data-resource]')].filter(img => (!want || want.has(img.dataset.resource)) && (() => {
    const clip = (img.closest('.freader-content') || img.closest('.page')).getBoundingClientRect();
    return [...img.getClientRects()].some(r => r.width > 0 && r.height > 0 && r.right > clip.left + .1 && r.left < clip.right - .1 && r.bottom > clip.top + .1 && r.top < clip.bottom - .1);
  })());
  for (const img of imgs) activeImagePaths.add(img.dataset.resource);
  for (const img of imgs) {
    if (!frame.isConnected || serial !== vSerial || disposed) return;
    try {
      const item = await imageFor(img.dataset.resource);
      if (!frame.isConnected) return;
      img.loading = 'eager'; img.src = item.url;
    } catch (error) { if (frame.isConnected) missingImage(img, error); }
  }
}
function vUpdate() {
  if (!vhost || !vTops.length || disposed) return;
  const st = vhost.scrollTop, H = vhost.clientHeight || innerHeight;
  const first = vIndexAt(st), last = vIndexAt(st + H);
  const current = vIndexAt(st + H * 0.33);
  if (current !== page) { page = current; reportLocation(); }
  let removed = false;
  const keepPage = (idx) => {
    const m = vMounted.get(idx);
    if (!m) return false;
    if (docxHandleFixedPt?.node && m.frame.contains(docxHandleFixedPt.node)) return true;
    if (docxSelRange && (m.frame.contains(docxSelRange.startContainer) || m.frame.contains(docxSelRange.endContainer))) return true;
    return false;
  };
  for (const index of [...vMounted.keys()]) if ((index < first - 3 || index > last + 3) && !keepPage(index)) { vUnmount(index); removed = true; }
  if (removed) {
    activeImagePaths = new Set();
    for (const m of vMounted.values()) for (const img of m.frame.querySelectorAll('img[data-resource][src]')) activeImagePaths.add(img.dataset.resource);
    trimImages();
  }
  const want = [];
  for (let i = Math.max(0, first - 1); i <= Math.min(pages.length - 1, last + 1); i++) if (!vMounted.has(i)) want.push(i);
  want.sort((a, b) => (a >= first && a <= last ? 0 : 1) - (b >= first && b <= last ? 0 : 1));
  let made = 0;
  for (const i of want) {
    if (made >= 2) { vSchedule(); break; }
    try { vMount(i); made++; } catch (error) { console.warn(error); }
  }
  if (made) applySearchHighlights();
}
// ── 파일 내 단어 검색: 찾은 곳은 노란 형광펜(CSS Highlight), 지금 보는 결과는 조금 진하게 ──
let searchState = { query: '', results: [], current: -1 };
function searchNorm(text) { return text.replace(/\u00a0/g, ' ').toLowerCase(); }
function textBlocksOf(root) {
  const blocks = []; let current = null;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const el = node.parentElement;
      if (!el || !node.data) return NodeFilter.FILTER_REJECT;
      if (el.closest('.docx-note-area, .odr-list-marker, style, script, .freader-missing-image')) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const key = node.parentElement.closest('x-p, li, td, th') || node.parentElement;
    if (!current || current.key !== key) { current = { key, nodes: [], text: '' }; blocks.push(current); }
    current.nodes.push({ node, start: current.text.length });
    current.text += node.data;
  }
  return blocks;
}
function pointAt(block, index) {
  let lo = 0;
  for (let i = 0; i < block.nodes.length; i++) if (block.nodes[i].start <= index) lo = i;
  const item = block.nodes[lo];
  return { node: item.node, offset: Math.min(item.node.data.length, index - item.start) };
}
async function search(query) {
  const q = searchNorm(String(query || '').trim());
  searchState = { query: q, results: [], current: -1 };
  if (!q || !pages.length) { applySearchHighlights(); return { count: 0, pages: [] }; }
  const pageOf = new Map();
  pages.forEach((entry, index) => {
    if (!pageOf.has(entry.source)) pageOf.set(entry.source, []);
    pageOf.get(entry.source)[entry.column] = index;
  });
  const results = [];
  for (const [source, columns] of pageOf) {
    const inner = source.querySelector('.freader-columns') || source.querySelector('.odr-page-inner');
    if (!inner) continue;
    const entry = pages[columns.find(i => i != null)];
    const innerRect = inner.getBoundingClientRect();
    const scale = inner.offsetWidth ? innerRect.width / inner.offsetWidth : 1;
    const stride = (entry.columnStride || entry.bodyWidth || inner.offsetWidth) * (scale || 1);
    for (const block of textBlocksOf(inner)) {
      const hay = searchNorm(block.text);
      for (let at = hay.indexOf(q); at >= 0; at = hay.indexOf(q, at + q.length)) {
        const start = pointAt(block, at), end = pointAt(block, at + q.length);
        const range = document.createRange();
        try { range.setStart(start.node, start.offset); range.setEnd(end.node, end.offset); } catch (_) { continue; }
        const rect = [...range.getClientRects()].find(r => r.width > 0 || r.height > 0);
        let column = 0;
        if (rect && stride > 0) column = Math.max(0, Math.floor((rect.left - innerRect.left + 0.5) / stride));
        const pageIndex = columns[Math.min(column, columns.length - 1)] ?? columns.find(i => i != null);
        if (pageIndex == null) continue;
        results.push({ page: pageIndex, start, end });
      }
    }
  }
  results.sort((a, b) => a.page - b.page);
  searchState.results = results;
  applySearchHighlights();
  return { count: results.length, pages: results.map(r => r.page) };
}
async function showSearchResult(index) {
  const r = searchState.results[index]; if (!r) return;
  searchState.current = index;
  if (vertical) { page = r.page; vGoto(r.page); vEnsureOriginal(r.page); applySearchHighlights(); reportLocation(); return; }
  const shown = [...host.children].some(frame => Number(frame.dataset.page) === r.page);
  if (shown) { applySearchHighlights(); return; }
  await display(r.page);
}
function clearSearch() { searchState = { query: '', results: [], current: -1 }; applySearchHighlights(); }
function applySearchHighlights() {
  if (typeof CSS === 'undefined' || !CSS.highlights || typeof Highlight === 'undefined') return;
  CSS.highlights.delete('freader-search'); CSS.highlights.delete('freader-search-current');
  if (!searchState.results.length) return;
  const container = vertical && vhost ? vhost : host;
  const visible = new Set(pageFrames().map(frame => Number(frame.dataset.page)));
  const all = [], current = [];
  searchState.results.forEach((r, i) => {
    if (!visible.has(r.page) || !r.start.node.isConnected || !container.contains(r.start.node)) return;
    const range = document.createRange();
    try { range.setStart(r.start.node, r.start.offset); range.setEnd(r.end.node, r.end.offset); } catch (_) { return; }
    (i === searchState.current ? current : all).push(range);
  });
  if (all.length) CSS.highlights.set('freader-search', new Highlight(...all));
  if (current.length) CSS.highlights.set('freader-search-current', new Highlight(...current));
}
/** 문단(글 덩어리)마다 글, 쪽, 굵기(전체/비율), 가운데 정렬, 글자 크기, 표 안인지 */
function outlineBlocks() {
  const pageOf = new Map(), blocks = [];
  pages.forEach((entry, index) => {
    if (!pageOf.has(entry.source)) pageOf.set(entry.source, []);
    pageOf.get(entry.source)[entry.column] = index;
  });
  for (const [source, columns] of pageOf) {
    const inner = source.querySelector('.freader-columns') || source.querySelector('.odr-page-inner');
    if (!inner) continue;
    const entry = pages[columns.find(i => i != null)];
    const innerRect = inner.getBoundingClientRect();
    const scale = inner.offsetWidth ? innerRect.width / inner.offsetWidth : 1;
    const stride = (entry.columnStride || entry.bodyWidth || inner.offsetWidth) * (scale || 1);
    for (const block of textBlocksOf(inner)) {
      let text = block.text.replace(/\s+/g, ' ').trim();
      if (!text) continue;
      // 자동 번호(1. 2. …)는 글이 아니라 따로 붙은 표시라서 앞에 붙여 줌 (목차의 '번호로 시작하는 줄' 판단용)
      const marker = block.key instanceof Element ? block.key.querySelector(':scope > .odr-list-marker')?.textContent?.trim() : '';
      if (marker && !text.startsWith(marker)) text = `${marker} ${text}`;
      let chars = 0, bold = 0, column = 0, fs = 0;
      for (const { node } of block.nodes) {
        const n = node.data.trim().length;
        if (!n) continue;
        chars += n;
        const cs = getComputedStyle(node.parentElement);
        fs = Math.max(fs, parseFloat(cs.fontSize) || 0);
        if ((parseInt(cs.fontWeight, 10) || 400) >= 600) bold += n;
      }
      if (!chars) continue;
      const range = document.createRange();
      try { range.selectNodeContents(block.nodes[0].node); } catch (_) {}
      const rect = [...range.getClientRects()].find(r => r.width > 0 || r.height > 0);
      if (rect && stride > 0) column = Math.max(0, Math.floor((rect.left - innerRect.left + 0.5) / stride));
      const page = columns[Math.min(column, columns.length - 1)] ?? columns.find(i => i != null);
      if (page == null) continue;
      let centered = false;
      try { centered = block.key instanceof Element && getComputedStyle(block.key).textAlign === 'center'; } catch (_) {}
      // 한 문단 안에서 줄을 바꿔(Shift+Enter) 붙인 부제목은 목차 제목에서 뺌: 첫 줄만
      let head = text;
      const br = block.key instanceof Element ? block.key.querySelector('br') : null;
      if (br) {
        const first = block.nodes.filter(({ node }) => node.compareDocumentPosition(br) & Node.DOCUMENT_POSITION_FOLLOWING)
          .map(({ node }) => node.data).join('').replace(/\s+/g, ' ').trim();
        if (first) head = marker && !first.startsWith(marker) ? `${marker} ${first}` : first;
      }
      blocks.push({ text, head, page, chars, fs, bold: bold >= chars * 0.9, boldRatio: bold / chars, centered, cell: !!block.key.closest?.('td, th') });
    }
  }
  return blocks;
}
/** 지금 화면에 보이는 글(낱말)과 그 위치 (화면 크기 대비 0~1) — 내보낸 PDF에 보이지 않는 글자 층을 넣는 데 씀 */
/** 쪽 하나에서 보이는 칸(본문 상자)에 놓인 글 조각들만 읽는 순서대로.
 * 쪽마다 구역 전체의 글이 옆으로 칸칸이 늘어서 있고 그중 한 칸만 보여서, 모든 글을 재면 큰 문서에서 수 초가 걸렸음.
 * 칸은 읽는 순서대로 왼쪽에서 오른쪽으로 놓이므로 양 끝을 반씩 좁혀 찾음 */
function docxPageTextNodes(pg, accept) {
  const nodes = [];
  const tw = document.createTreeWalker(pg, NodeFilter.SHOW_TEXT);
  for (let n = tw.nextNode(); n; n = tw.nextNode()) if (n.data.trim() && (!accept || accept(n))) nodes.push(n);
  const clipEl = pg.querySelector('.freader-content');
  if (!clipEl || nodes.length < 64) return nodes;
  const cq = clipEl.getBoundingClientRect();
  if (!(cq.width > 0)) return nodes;
  const r = document.createRange();
  const box = (n) => { r.selectNodeContents(n); return r.getBoundingClientRect(); };
  let lo = 0, hi = nodes.length;
  while (lo < hi) { const m = (lo + hi) >> 1; if (box(nodes[m]).right <= cq.left + 0.5) lo = m + 1; else hi = m; }
  const first = lo;
  hi = nodes.length;
  while (lo < hi) { const m = (lo + hi) >> 1; if (box(nodes[m]).left < cq.right - 0.5) lo = m + 1; else hi = m; }
  return nodes.slice(Math.max(0, first - 24), Math.min(nodes.length, lo + 24));
}
function visibleTextBoxes() {
  const W = innerWidth || 1, H = innerHeight || 1, out = [];
  const inV = vertical && vhost;
  const range = document.createRange();
  for (const pg of (inV ? vhost : host).querySelectorAll('.page')) {
    const pr = pg.getBoundingClientRect();
    if (pr.bottom <= 0 || pr.top >= H || pr.right <= 0 || pr.left >= W) continue;
    // 스크롤 보기: 낱말이 몇째 쪽 어디에 있는지도 알려 줌 (앱이 고른 글 바탕을 쪽에 붙여 그림)
    const slot = inV ? pg.closest('.vslot') : null;
    if (inV && !slot) continue;
    const sq = slot ? (slot.querySelector(':scope > .vfull') || slot).getBoundingClientRect() : null;
    // 본문 상자 밖(다른 쪽 몫으로 옆에 밀려나 가려진 글)은 고를 수 없게
    const clipEl = pg.querySelector('.freader-content');
    const cq = clipEl ? clipEl.getBoundingClientRect() : null;
    for (const node of docxPageTextNodes(pg)) {
      const data = node.data;
      const word = /\S+/g;
      for (let m = word.exec(data); m; m = word.exec(data)) {
        try { range.setStart(node, m.index); range.setEnd(node, m.index + m[0].length); } catch (_) { continue; }
        const r = [...range.getClientRects()].find(rect => rect.width >= 0.5 && rect.height >= 0.5);
        if (!r || r.right <= 0 || r.bottom <= 0 || r.left >= W || r.top >= H) continue;
        if (cq && Math.min(cq.right, r.right) - Math.max(cq.left, r.left) < r.width * 0.6) continue;
        const o = { t: m[0], x: r.left / W, y: r.top / H, w: r.width / W, h: r.height / H };
        if (sq && sq.width > 0 && sq.height > 0) {
          o.p = Number(slot.dataset.page);
          o.px = (r.left - sq.left) / sq.width; o.py = (r.top - sq.top) / sq.height;
          o.pw = r.width / sq.width; o.ph = r.height / sq.height;
        }
        out.push(o);
        if (out.length >= 20000) return out;
      }
    }
  }
  return out;
}
/** 쪽마다의 글 (문단마다 줄바꿈) — 앱이 '목차' 쪽을 찾는 데 씀 */
function pageText(from, to) {
  if (!pages.length) return [];
  if (!outlineBlockCache) outlineBlockCache = outlineBlocks();
  const end = Math.min(pages.length, Math.max(0, to | 0));
  const out = [];
  for (let i = Math.max(0, from | 0); i < end; i++) out.push([]);
  for (const b of outlineBlockCache) if (b.page >= from && b.page < end) out[b.page - from].push(b.text);
  return out.map(lines => lines.join('\n'));
}
// ── 목차 후보: 번호로 시작하거나 굵은 글씨가 있는 짧은 문단 {title, page, bold, boldRatio, centered, fs} (표 안 제외)
// 앱이 '목차 쪽 → 번호 → 굵은 글씨(가운데 정렬 또는 전체 굵게)' 순서로 고른다 ──
const NUMBERED_START = /^\s*(?:[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ]|[IVX]{1,5}\s*[.)]|\(\s*\d|\d)/;
function headingCandidates() {
  if (!pages.length) return [];
  if (!outlineBlockCache) outlineBlockCache = outlineBlocks();
  // 본문 글자 크기 = 문서 전체에서 가장 많이 쓴 크기 (글자 수 기준)
  const sizeChars = new Map();
  for (const b of outlineBlockCache) if (b.fs > 0) sizeChars.set(b.fs, (sizeChars.get(b.fs) || 0) + b.chars);
  let body = 0, most = -1;
  for (const [k, n] of sizeChars) if (n > most) { most = n; body = k; }
  return outlineBlockCache.filter(b => !b.cell && (b.head || b.text).length <= 100 && (NUMBERED_START.test(b.head || b.text) || b.boldRatio >= 0.5))
    .slice(0, 3000).map(b => ({ title: b.head || b.text, page: b.page, bold: b.bold, boldRatio: b.boldRatio, centered: b.centered, fs: b.fs, body }));
}

// ── 확대해 둔 화면을 선명하게: 앱이 화면 그림을 키우는 대신, 쪽 상자 자체를 그 배율로 다시 그림 ──
// (앱은 그 배율만큼 화면 그림을 되돌려 겹치게 하므로 보이는 자리는 그대로, 글씨만 선명해짐)
let zoomView = null, zoomBase = [0, 0]; // [배율, 가로 이동, 세로 이동] (CSS px), 확대 전 문서 화면 크기
// 넘겨 보기 확대: 손가락이 움직이는 동안에는 이미 그려 둔 그림을 옮기고 크기만 바꿔(빠름)
// 손가락이 멈추면 그 배율로 쪽을 다시 놓아 또렷하게. 줄일 때 아직 안 그려진 가장자리는 밑그림(1배 쪽 복사본)이 채움
let zoomDrawn = 1, zoomSettle = 0, zoomUnder = null;
function zoomApply() {
  const [s, tx, ty] = zoomView;
  host.style.transform = `translate(${tx}px, ${ty}px) scale(${s / zoomDrawn})`;
  if (zoomUnder) zoomUnder.style.transform = `matrix(${s}, 0, 0, ${s}, ${tx}, ${ty})`;
}
/** [zoomDrawn] 배율로 쪽을 다시 놓음 (문서 화면도 그만큼 크게 — 잘리는 곳이 없게) */
function zoomRedraw() {
  Object.assign(host.style, { width: `${zoomBase[0] * zoomDrawn}px`, height: `${zoomBase[1] * zoomDrawn}px`, gap: zoomDrawn === 1 ? '' : `${(8 / 3) * zoomDrawn}px` });
  fitPages();
  zoomApply();
}
function zoomMakeUnder() {
  zoomUnder?.remove();
  const u = host.cloneNode(true);
  u.removeAttribute('id'); u.id = 'pages-under'; u.setAttribute('aria-hidden', 'true');
  Object.assign(u.style, { transform: '', width: `${zoomBase[0]}px`, height: `${zoomBase[1]}px`, display: '' });
  host.parentNode.insertBefore(u, host);
  zoomUnder = u;
}
function zoomClear() {
  clearTimeout(zoomSettle); zoomSettle = 0;
  zoomView = null; zoomDrawn = 1;
  zoomUnder?.remove(); zoomUnder = null;
  host.classList.remove('zooming');
  Object.assign(host.style, { transform: '', width: '', height: '', gap: '' });
  fitPages();
}
function setView(s, tx, ty) {
  if (docxEditMode) markDocxScrolling();
  if (!(s > 1.001)) { if (zoomView) zoomClear(); return true; }
  if (!zoomView) {
    zoomBase = [host.clientWidth, host.clientHeight]; zoomDrawn = 1;
    zoomMakeUnder();
    host.classList.add('zooming');
    zoomView = [s, tx, ty];
    zoomRedraw();
  } else {
    zoomView = [s, tx, ty];
    zoomApply();
  }
  clearTimeout(zoomSettle);
  zoomSettle = setTimeout(() => {
    zoomSettle = 0;
    if (!zoomView || Math.abs(zoomView[0] - zoomDrawn) < 0.005) return;
    zoomDrawn = zoomView[0];
    zoomRedraw();
  }, 140);
  return true;
}
// 자리를 재는 일(쪽 위치·글자 상자·표시)은 확대하지 않은 자리로 (앱 쪽 좌표와 맞게)
function withoutZoom(fn) {
  return function (...args) {
    if (!zoomView) return fn.apply(this, args);
    // 확대 전 자리로 잠깐 되돌려 잰 뒤 다시 확대
    const keep = zoomDrawn;
    zoomDrawn = 1;
    Object.assign(host.style, { transform: '', width: `${zoomBase[0]}px`, height: `${zoomBase[1]}px`, gap: '' });
    fitPages();
    try { return fn.apply(this, args); } finally { zoomDrawn = keep; zoomRedraw(); }
  };
}

// ============================================================
// Word (.docx) 문서 직접 편집 기능 (HWP와 동일한 숨김 IME + 커스텀 커서 + 커스텀 하이라이트·손잡이)
// - contentEditable 미사용 → 안드로이드 커서 물방울 손잡이·더블탭 선택·touchend 선택 사라짐 원천 차단
// ============================================================
let docxEditMode = false;
let docxEditDirty = false;
let docxEditOrigHtml = [];
let docxOrigParas = new Map(); // 원본 문단 번호 → 편집 시작 때 상태 { text, fmt, imgs }
let docxUndoStack = [];
let docxRedoStack = [];
let docxLastSnap = null;
let docxKbInset = 0;

let docxImeEl = null;
let docxImeComposing = false;
let docxLastCompEndAt = 0;
let docxLastCompEndText = '';
let docxImeCompNode = null;
let docxImeCompBase = 0;
let docxImeCompLen = 0;
let docxSuppressImeReset = false;

let docxCursor = null;        // { node: Text, offset: number }
let docxSelRange = null;      // Range (non-collapsed custom selection)
let docxPendingFmt = {};      // { bold?, italic?, underline?, fontSizePt?, textColor? }

let docxSelTimer = 0;
let docxSelDragging = false;
let docxSelDownX = 0;
let docxSelDownY = 0;
let docxSelAnchorPt = null;   // { node: Text, offset: number }
let docxSelJustEndedAt = 0;

function docxUniqueSources() {
  const seen = new Set();
  const out = [];
  for (const entry of pages) {
    const src = entry && entry.source && typeof entry.source.querySelectorAll === 'function' ? entry.source : null;
    if (src && !seen.has(src)) {
      seen.add(src);
      out.push(src);
    }
  }
  return out;
}

function docxSnapshotPages() {
  return docxUniqueSources().map(src => src.innerHTML);
}

function docxApplySnapshot(snap) {
  if (!Array.isArray(snap)) return;
  const srcs = docxUniqueSources();
  for (let i = 0; i < Math.min(srcs.length, snap.length); i++) {
    srcs[i].innerHTML = snap[i];
  }
  // 되살린 글 덩어리에는 찍어 둘 때의 쪽 자리(가로 위치)가 들어 있으므로 지금 보이는 쪽 자리로 맞춤
  if (vertical && vhost) {
    for (const [i, m] of vMounted) if (m.original) preparePageSource(m.source, m.entry, i);
  } else {
    for (const frame of host.querySelectorAll(':scope > .page')) {
      const idx = Number(frame.dataset.page), src = frame.firstElementChild;
      if (pages[idx] && src && pages[idx].source === src) preparePageSource(src, pages[idx], idx);
    }
  }
}

function docxRgbToHex(rgb) {
  if (!rgb) return '#000000';
  if (rgb.startsWith('#')) return rgb.length === 7 ? rgb : '#000000';
  const m = /rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i.exec(rgb);
  if (!m) return '#000000';
  const h = n => Math.max(0, Math.min(255, Number(n))).toString(16).padStart(2, '0');
  return `#${h(m[1])}${h(m[2])}${h(m[3])}`;
}

function docxEnsureIme() {
  if (docxImeEl) return docxImeEl;
  const el = document.createElement('textarea');
  el.id = 'eri-docx-ime';
  el.setAttribute('autocomplete', 'off');
  el.setAttribute('autocorrect', 'off');
  el.setAttribute('autocapitalize', 'off');
  el.setAttribute('spellcheck', 'false');
  el.setAttribute('inputmode', 'text');
  Object.assign(el.style, {
    position: 'fixed',
    left: '-9999px',
    top: '0px',
    width: '2px',
    height: '2px',
    opacity: '0',
    pointerEvents: 'none',
    zIndex: '-1',
  });
  document.body.appendChild(el);
  docxImeEl = el;

  el.addEventListener('compositionstart', () => {
    if (docxSuppressImeReset || !docxEditMode || !docxCursor) return;
    if (docxSelRange && !docxSelRange.collapsed) docxDeleteSelection();
    docxImeComposing = true;
    docxPrepareStyledInsertNode();
    docxImeCompNode = docxCursor.node;
    docxImeCompBase = docxCursor.offset;
    docxImeCompLen = 0;
  });

  el.addEventListener('compositionupdate', (e) => {
    if (docxSuppressImeReset || !docxEditMode || !docxCursor) return;
    const str = String(e.data ?? '').replace(/\u200B/g, '');
    if (!docxImeCompNode || !docxImeCompNode.isConnected) {
      docxImeCompNode = docxCursor.node;
      docxImeCompBase = docxCursor.offset;
      docxImeCompLen = 0;
    }
    const curVal = docxImeCompNode.nodeValue || '';
    const before = curVal.slice(0, docxImeCompBase);
    const after = curVal.slice(docxImeCompBase + docxImeCompLen);
    docxImeCompNode.nodeValue = before + str + after;
    docxImeCompLen = str.length;
    docxCursor = { node: docxImeCompNode, offset: docxImeCompBase + docxImeCompLen };
    docxEditDirty = true;
    docxRenderCaret();
    docxEmitEditState(true);
  });

  el.addEventListener('compositionend', (e) => {
    if (docxSuppressImeReset || !docxImeComposing) {
      docxImeComposing = false;
      docxImeCompLen = 0;
      docxImeCompNode = null;
      return;
    }
    if (!docxEditMode || !docxCursor) {
      docxImeComposing = false;
      docxImeCompLen = 0;
      docxImeCompNode = null;
      docxResetImeBuffer();
      return;
    }
    const str = String(e.data ?? '').replace(/\u200B/g, '');
    if (docxImeCompNode && docxImeCompNode.isConnected) {
      const curVal = docxImeCompNode.nodeValue || '';
      const before = curVal.slice(0, docxImeCompBase);
      const after = curVal.slice(docxImeCompBase + docxImeCompLen);
      docxImeCompNode.nodeValue = before + str + after;
      docxCursor = { node: docxImeCompNode, offset: docxImeCompBase + str.length };
      docxPushUndo();
    }
    docxLastCompEndAt = Date.now();
    docxLastCompEndText = str;
    docxImeComposing = false;
    docxImeCompLen = 0;
    docxImeCompNode = null;
    docxResetImeBuffer();
    docxRenderCaret();
    docxEmitEditState(true);
  });

  el.addEventListener('input', (e) => {
    if (docxSuppressImeReset || !docxEditMode || !docxCursor || docxImeComposing || e.isComposing) return;
    const it = e.inputType || '';
    // Android WebView + 삼성 키보드가 compositionend 직후 중복으로 흘리는 조합 완료 input 차단
    if (it === 'insertCompositionText' || it === 'insertFromComposition') {
      docxResetImeBuffer();
      return;
    }
    const rawVal = el.value || '';
    const cleanPre = rawVal.replace(/\u200B/g, '');
    if (cleanPre.length > 0 && Date.now() - docxLastCompEndAt < 140 && cleanPre === docxLastCompEndText) {
      docxLastCompEndAt = 0;
      docxResetImeBuffer();
      return;
    }
    if (it === 'deleteContentBackward' || rawVal.length === 0) {
      docxHandleBackspace();
      docxResetImeBuffer();
      docxEmitEditState(true);
      return;
    }
    if (it === 'insertLineBreak' || it === 'insertParagraph') {
      docxHandleEnter();
      docxResetImeBuffer();
      docxEmitEditState(true);
      return;
    }
    const clean = rawVal.replace(/\u200B/g, '');
    if (clean.includes('\n')) {
      const parts = clean.split('\n');
      for (let i = 0; i < parts.length; i++) {
        if (parts[i].length > 0) docxInsertTextAtCursor(parts[i]);
        if (i < parts.length - 1) docxHandleEnter();
      }
      docxResetImeBuffer();
      docxEmitEditState(true);
      return;
    }
    if (clean.length > 0) {
      docxInsertTextAtCursor(clean);
      docxResetImeBuffer();
      docxEmitEditState(true);
    }
  });

  el.addEventListener('keydown', (e) => {
    if (!docxEditMode || !docxCursor || docxImeComposing) return;
    if (e.key === 'Backspace') {
      e.preventDefault();
      docxHandleBackspace();
      docxResetImeBuffer();
      docxEmitEditState(true);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      docxHandleEnter();
      docxResetImeBuffer();
      docxEmitEditState(true);
    }
  });

  el.addEventListener('blur', () => {
    if (docxEditMode && !docxSuppressImeReset && (docxSelDragging || docxActiveHandleSide || docxSelTimer)) {
      try { el.focus({ preventScroll: true }); } catch (_) {}
    }
  });

  return el;
}

function docxPreventBlurMouseDown(e) {
  if (!docxEditMode || !docxImeEl) return;
  if (document.activeElement === docxImeEl && e.target !== docxImeEl) {
    e.preventDefault();
  }
}

function docxResetImeBuffer() {
  if (!docxImeEl) return;
  const prev = docxSuppressImeReset;
  docxSuppressImeReset = true;
  try {
    docxImeEl.value = '\u200B';
    docxImeEl.setSelectionRange(1, 1);
  } catch (_) {}
  docxSuppressImeReset = prev;
}

function docxFocusIme() {
  docxSuppressImeReset = false;
  const el = docxEnsureIme();
  el.disabled = false;
  el.style.display = '';
  docxResetImeBuffer();
  try { el.focus({ preventScroll: true }); } catch (_) {}
  try { el.setSelectionRange(1, 1); } catch (_) {}
}

function docxHasPendingFmt() {
  return docxPendingFmt.bold !== undefined ||
    docxPendingFmt.italic !== undefined ||
    docxPendingFmt.underline !== undefined ||
    docxPendingFmt.fontSizePt !== undefined ||
    docxPendingFmt.textColor !== undefined;
}

function docxPrepareStyledInsertNode() {
  if (!docxCursor || !docxCursor.node || !docxCursor.node.isConnected) return;
  if (!docxHasPendingFmt()) return;
  const node = docxCursor.node;
  const off = Math.max(0, Math.min(node.nodeValue.length, docxCursor.offset));
  const afterNode = node.splitText(off);
  const span = document.createElement('span');
  span.dataset.eriFmt = '1';
  if (docxPendingFmt.bold !== undefined) span.style.fontWeight = docxPendingFmt.bold ? 'bold' : 'normal';
  if (docxPendingFmt.italic !== undefined) span.style.fontStyle = docxPendingFmt.italic ? 'italic' : 'normal';
  if (docxPendingFmt.underline !== undefined) span.style.textDecoration = docxPendingFmt.underline ? 'underline' : 'none';
  if (docxPendingFmt.fontSizePt !== undefined) {
    const pt = Number(docxPendingFmt.fontSizePt);
    span.style.fontSize = `${pt}pt`;
    span.style.lineHeight = '1.45';
    const paraEl = afterNode.parentElement?.closest?.('x-p, p');
    if (paraEl) {
      const curLh = parseFloat(getComputedStyle(paraEl).lineHeight);
      if (Number.isFinite(curLh) && curLh < pt * 1.45 * 1.333) {
        paraEl.style.lineHeight = '1.45';
      }
    }
  }
  if (docxPendingFmt.textColor !== undefined) span.style.color = docxPendingFmt.textColor;
  const newText = document.createTextNode('');
  span.appendChild(newText);
  afterNode.parentNode.insertBefore(span, afterNode);
  docxCursor = { node: newText, offset: 0 };
  docxPendingFmt = {};
}

function docxInsertTextAtCursor(text) {
  if (!docxCursor || !text) return;
  if (docxSelRange && !docxSelRange.collapsed) docxDeleteSelection();
  docxPrepareStyledInsertNode();
  const node = docxCursor.node;
  if (!node || !node.isConnected) return;
  const val = node.nodeValue || '';
  const off = Math.max(0, Math.min(val.length, docxCursor.offset));
  node.nodeValue = val.slice(0, off) + text + val.slice(off);
  docxCursor = { node, offset: off + text.length };
  docxPushUndo();
  docxRenderCaret();
}

function docxFindPrevTextNode(node) {
  const page = node?.parentElement?.closest?.('.page');
  if (!page) return null;
  const tw = document.createTreeWalker(page, NodeFilter.SHOW_TEXT);
  let prev = null;
  let cur = tw.nextNode();
  while (cur) {
    if (cur === node) return prev;
    if ((cur.nodeValue || '').length > 0) prev = cur;
    cur = tw.nextNode();
  }
  return null;
}

function docxDeleteSelection() {
  if (!docxSelRange || docxSelRange.collapsed) return false;
  try {
    const r = docxSelRange.cloneRange();
    const startNode = r.startContainer;
    const startOff = r.startOffset;
    r.deleteContents();
    let targetNode = startNode;
    let targetOff = startOff;
    if (targetNode.nodeType !== 3 || !targetNode.isConnected) {
      const t = document.createTextNode('');
      r.insertNode(t);
      targetNode = t;
      targetOff = 0;
    } else {
      targetOff = Math.max(0, Math.min(targetNode.nodeValue.length, startOff));
    }
    docxSelRange = null;
    docxClearSelectionOverlays();
    docxCursor = { node: targetNode, offset: targetOff };
    docxPushUndo();
    docxRenderCaret();
    return true;
  } catch (_) {
    return false;
  }
}

function docxHandleBackspace() {
  if (docxSelRange && !docxSelRange.collapsed) {
    docxDeleteSelection();
    return;
  }
  if (!docxCursor || !docxCursor.node || !docxCursor.node.isConnected) return;
  let { node, offset } = docxCursor;
  if (offset > 0) {
    const val = node.nodeValue || '';
    node.nodeValue = val.slice(0, offset - 1) + val.slice(offset);
    docxCursor = { node, offset: offset - 1 };
    docxPushUndo();
    docxRenderCaret();
    return;
  }
  const prev = docxFindPrevTextNode(node);
  if (prev) {
    const val = prev.nodeValue || '';
    if (val.length > 0) {
      prev.nodeValue = val.slice(0, val.length - 1);
      docxCursor = { node: prev, offset: prev.nodeValue.length };
      docxPushUndo();
      docxRenderCaret();
    }
  }
}

function docxHandleEnter() {
  if (!docxCursor || !docxCursor.node || !docxCursor.node.isConnected) return;
  if (docxSelRange && !docxSelRange.collapsed) docxDeleteSelection();
  const { node, offset } = docxCursor;
  const after = node.splitText(Math.max(0, Math.min(node.nodeValue.length, offset)));
  const br = document.createElement('br');
  after.parentNode.insertBefore(br, after);
  docxCursor = { node: after, offset: 0 };
  docxPushUndo();
  docxRenderCaret();
}

let docxCaretHandleEl = null;
let docxCaretHandleDragging = false;

function docxRemoveCaret(keepHandle = false) {
  for (const el of document.querySelectorAll('.eri-docx-caret')) el.remove();
  if (!keepHandle) {
    for (const el of document.querySelectorAll('.eri-caret-handle')) el.remove();
    docxCaretHandleEl = null;
  }
}

function docxMountCaretHandle(pageEl, leftPct, topPct) {
  if (!pageEl) return;
  if (!docxCaretHandleEl) {
    const h = document.createElement('div');
    h.className = 'eri-caret-handle';
    docxCaretHandleEl = h;
  }
  const cx = Math.max(1, Math.min(99, Number(leftPct) || 0));
  const cy = Math.max(1, Math.min(99, Number(topPct) || 0));
  if (vertical && vinner) {
    const full = pageEl.closest?.('.vfull'), slot = pageEl.closest?.('.vslot') || pageEl;
    const box = full || slot, ox = full ? slot.offsetLeft + full.offsetLeft : slot.offsetLeft, oy = full ? slot.offsetTop + full.offsetTop : slot.offsetTop;
    const lx = ox + (cx / 100) * box.offsetWidth;
    const ly = oy + (cy / 100) * box.offsetHeight;
    docxCaretHandleEl.style.left = `${lx}px`;
    docxCaretHandleEl.style.top = `${ly}px`;
    if (docxCaretHandleEl.parentNode !== vinner) vinner.appendChild(docxCaretHandleEl);
  } else {
    docxCaretHandleEl.style.left = `${cx}%`;
    docxCaretHandleEl.style.top = `${cy}%`;
    if (docxCaretHandleEl.parentNode !== pageEl) pageEl.appendChild(docxCaretHandleEl);
  }
  docxCaretHandleEl.style.marginLeft = '-24px';
  docxCaretHandleEl.style.marginTop = '-2px';
  docxCaretHandleEl.style.display = 'block';
  docxCaretHandleEl.style.visibility = 'visible';
  docxCaretHandleEl.style.zIndex = '45';
}

const docxHandleEls = { start: null, end: null };

function docxClearSelectionOverlays(keepHandles = false) {
  for (const el of document.querySelectorAll('.eri-docx-sel-rect')) el.remove();
  docxSelPages.clear();
  if (!keepHandles) {
    for (const el of document.querySelectorAll('.eri-sel-handle')) el.remove();
    docxHandleEls.start = null;
    docxHandleEls.end = null;
  }
}

function docxRenderCaret() {
  docxRemoveCaret(docxCaretHandleDragging);
  if (!docxEditMode || !docxCursor || !docxCursor.node || !docxCursor.node.isConnected) return;
  if (docxSelRange && !docxSelRange.collapsed) return;
  try {
    const { node, offset } = docxCursor;
    const len = (node.nodeValue || '').length;
    const off = Math.max(0, Math.min(len, offset));
    const r = document.createRange();
    r.setStart(node, off);
    r.collapse(true);
    let rect = r.getBoundingClientRect();
    if (!(rect.height > 0)) {
      const parentEl = node.parentElement;
      if (parentEl) rect = parentEl.getBoundingClientRect();
    }
    const pageEl = node.parentElement?.closest?.('#pages > .page, #vpages .page');
    if (!pageEl || !(rect.height > 0)) return;
    const pr = pageEl.getBoundingClientRect();
    const caret = document.createElement('div');
    caret.className = 'eri-docx-caret';
    caret.style.left = `${(Math.max(0, rect.left - pr.left) / Math.max(1, pr.width)) * 100}%`;
    caret.style.top = `${(Math.max(0, rect.top - pr.top) / Math.max(1, pr.height)) * 100}%`;
    caret.style.height = `${(Math.max(12, rect.height) / Math.max(1, pr.height)) * 100}%`;
    pageEl.appendChild(caret);
    const hLeftPct = (Math.max(0, rect.left - pr.left) / Math.max(1, pr.width)) * 100;
    const hTopPct = (Math.max(0, rect.bottom - pr.top) / Math.max(1, pr.height)) * 100;
    docxMountCaretHandle(pageEl, hLeftPct, hTopPct);
  } catch (_) {}
}

function docxFindOffsetInTextNode(tn, x, y) {
  const txt = tn.nodeValue || '';
  const len = txt.length;
  if (len === 0) return 0;
  const cr = document.createRange();
  // 여러 줄에 걸친 텍스트 노드도 정확한 Y 줄 + X 글자 위치로 찾음
  let bestOff = 0, bestScore = Infinity;
  // 긴 텍스트 노드는 8글자 단위로 먼저 근접 구간을 좁힌 뒤 주변 정밀 탐색
  const step = len > 48 ? 8 : 1;
  let approx = 0;
  if (step > 1) {
    let minS = Infinity;
    for (let i = 0; i < len; i += step) {
      cr.setStart(tn, i);
      cr.setEnd(tn, Math.min(len, i + 1));
      const br = cr.getBoundingClientRect();
      if (!(br.height > 0)) continue;
      const dy = y < br.top ? br.top - y : (y > br.bottom ? y - br.bottom : 0);
      const dx = Math.abs((br.left + br.right) * 0.5 - x);
      const s = dy * dy * 12 + dx * dx;
      if (s < minS) { minS = s; approx = i; }
    }
  }
  const startI = step > 1 ? Math.max(0, approx - 12) : 0;
  const endI = step > 1 ? Math.min(len - 1, approx + 12) : len - 1;
  for (let i = startI; i <= endI; i++) {
    cr.setStart(tn, i);
    cr.setEnd(tn, i + 1);
    const br = cr.getBoundingClientRect();
    if (!(br.height > 0)) continue;
    const dy = y < br.top ? br.top - y : (y > br.bottom ? y - br.bottom : 0);
    const midX = (br.left + br.right) * 0.5;
    const dx = Math.abs(midX - x);
    const s = dy * dy * 16 + dx * dx;
    if (s < bestScore) {
      bestScore = s;
      bestOff = x >= midX ? i + 1 : i;
    }
  }
  return Math.max(0, Math.min(len, bestOff));
}

function docxValidPageTextNode(tn) {
  if (!tn || tn.nodeType !== 3) return false;
  if ((tn.nodeValue || '').trim().length === 0) return false;
  const pe = tn.parentElement;
  if (!pe) return false;
  const pg = pe.closest?.('.page');
  if (!pg || pg.closest?.('#pages-under')) return false;
  if (pe.closest?.('#measure, .eri-sel-handle, .docx-note-area')) return false;
  return true;
}

function docxCaretPointAt(clientX, clientY) {
  // 핸들 2개만 잠시 pointer-events: none 처리 (visibility 토글 없이 리페인트/깜빡임 0)
  const hEls = [docxHandleEls.start, docxHandleEls.end, docxCaretHandleEl].filter(Boolean);
  for (const h of hEls) h.style.pointerEvents = 'none';
  try {
    const tryAt = (x, y) => {
      let r = null;
      if (typeof document.caretRangeFromPoint === 'function') {
        r = document.caretRangeFromPoint(x, y);
      } else if (typeof document.caretPositionFromPoint === 'function') {
        const p = document.caretPositionFromPoint(x, y);
        if (p && p.offsetNode) {
          r = document.createRange();
          r.setStart(p.offsetNode, p.offset);
          r.collapse(true);
        }
      }
      if (r && r.startContainer && r.startContainer.nodeType === 3 && docxValidPageTextNode(r.startContainer)) {
        // 빈 여백/문단 사이에서 페이지 맨 위 노드로 튀는 오판 차단: 실제 글자 사각형과 거리 검증
        const len = (r.startContainer.nodeValue || '').length;
        const off = Math.max(0, Math.min(len, r.startOffset));
        const cr = document.createRange();
        cr.setStart(r.startContainer, Math.min(off, Math.max(0, len - 1)));
        cr.setEnd(r.startContainer, Math.min(len, Math.min(off, Math.max(0, len - 1)) + 1));
        const br = cr.getBoundingClientRect();
        if (br.height > 0 && br.height < 100) {
          const dy = y < br.top ? br.top - y : (y > br.bottom ? y - br.bottom : 0);
          const dx = x < br.left ? br.left - x : (x > br.right ? x - br.right : 0);
          if ((dy <= 14 && dx <= 260) || (dy <= 26 && dx <= 64)) {
            return { node: r.startContainer, offset: off };
          }
        }
      }
      return null;
    };
    let pt = tryAt(clientX, clientY);
    if (pt) return pt;
    for (const dx of [10, -10, 20, -20]) {
      pt = tryAt(clientX + dx, clientY);
      if (pt) return pt;
    }
    // 빈 간격/줄 사이 폴백: 현재 좌표에 실제로 가장 가까운 텍스트 노드(수직 32px 이내)만 정확히 선택
    for (const pg of document.querySelectorAll('#pages > .page, #vpages .page')) {
      if (pg.closest?.('#pages-under')) continue;
      const pr = pg.getBoundingClientRect();
      if (clientX >= pr.left - 24 && clientX <= pr.right + 24 && clientY >= pr.top - 16 && clientY <= pr.bottom + 16) {
        const clips = new Map();
        let best = null, bestDist = Infinity;
        for (const tn of docxPageTextNodes(pg, docxValidPageTextNode)) {
          // 본문 상자 밖(다른 쪽 몫으로 옆에 밀려나 가려진 글)은 후보에서 뺌 — 쪽 왼쪽 끝 가까이 끌면 엉뚱한 곳으로 튀었음
          const clipEl = tn.parentElement.closest('.freader-content');
          let cq = clips.get(clipEl);
          if (cq === undefined) { cq = clipEl ? clipEl.getBoundingClientRect() : null; clips.set(clipEl, cq); }
          const nr = document.createRange();
          nr.selectNodeContents(tn);
          for (const rc of nr.getClientRects()) {
            if (cq && Math.min(cq.right, rc.right) - Math.max(cq.left, rc.left) < rc.width * 0.6) continue;
            if (rc.width > 0.5 && rc.height > 0.5 && rc.height < 100) {
              const dy0 = clientY < rc.top ? rc.top - clientY : (clientY > rc.bottom ? clientY - rc.bottom : 0);
              if (dy0 > 90) continue;
              const dx0 = clientX < rc.left ? rc.left - clientX : (clientX > rc.right ? clientX - rc.right : 0);
              const d = dy0 * dy0 * 9 + dx0 * dx0;
              if (d < bestDist) { bestDist = d; best = tn; }
            }
          }
        }
        if (best && bestDist < 12000) {
          return { node: best, offset: docxFindOffsetInTextNode(best, clientX, clientY) };
        }
      }
    }
  } catch (_) {}
  finally {
    for (const h of hEls) h.style.pointerEvents = '';
  }
  return null;
}

function docxComparePts(a, b) {
  if (a.node === b.node) return a.offset - b.offset;
  const pos = a.node.compareDocumentPosition(b.node);
  if (pos & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
  if (pos & Node.DOCUMENT_POSITION_PRECEDING) return 1;
  return 0;
}

function docxBuildRangeFromPts(p1, p2) {
  if (!p1 || !p2 || !p1.node?.isConnected || !p2.node?.isConnected) return null;
  const cmp = docxComparePts(p1, p2);
  const st = cmp <= 0 ? p1 : p2;
  const en = cmp <= 0 ? p2 : p1;
  const range = document.createRange();
  let sOff = Math.max(0, Math.min(st.node.nodeValue.length, st.offset));
  let eOff = Math.max(0, Math.min(en.node.nodeValue.length, en.offset));
  if (st.node === en.node && sOff === eOff) {
    const len = st.node.nodeValue.length;
    if (len > 0) {
      if (sOff >= len) sOff = len - 1;
      eOff = Math.min(len, sOff + 1);
    }
  }
  range.setStart(st.node, sOff);
  range.setEnd(en.node, eOff);
  return range;
}

let docxActiveHandleSide = null;
let docxDragRaf = 0;
let docxDragPending = null;

function docxCancelDragRaf() {
  if (docxDragRaf) { cancelAnimationFrame(docxDragRaf); docxDragRaf = 0; }
  docxDragPending = null;
}
let docxHandleFixedPt = null;

let docxAutoScrollRaf = 0;
let docxAutoScrollPt = null;

function stopDocxAutoScroll() {
  if (docxAutoScrollRaf) { cancelAnimationFrame(docxAutoScrollRaf); docxAutoScrollRaf = 0; }
  docxAutoScrollPt = null;
}

let docxLastPtNode = null;
let docxLastPtOff = -1;
let docxCaretStartPt = null;
let docxCaretMoved = false;

function applyDocxHandlePoint(x, y) {
  const pt = docxCaretPointAt(x, docxCaretHandleDragging ? (y - 26) : (y - 18));
  if (!pt) return;
  if (pt.node === docxLastPtNode && pt.offset === docxLastPtOff) return;
  docxLastPtNode = pt.node;
  docxLastPtOff = pt.offset;
  if (docxCaretHandleDragging) {
    docxCursor = { ...pt };
    docxSelRange = null;
    docxRenderCaret();
    return;
  }
  if (!docxActiveHandleSide || !docxHandleFixedPt) return;
  const next = docxBuildRangeFromPts(docxHandleFixedPt, pt);
  if (next && !next.collapsed) {
    docxSelRange = next;
    docxRenderSelection();
  }
}

function tickDocxAutoScroll() {
  docxAutoScrollRaf = 0;
  if ((!docxActiveHandleSide && !docxCaretHandleDragging) || !docxAutoScrollPt || !vertical || !vhost) return;
  const { x, y } = docxAutoScrollPt;
  const topEdge = 64;
  const botEdge = window.innerHeight - (docxKbInset > 0 ? docxKbInset + 72 : 48);
  let dy = 0;
  if (y > botEdge - 68) {
    dy = Math.min(20, Math.max(5, ((y - (botEdge - 68)) / 68) * 16));
  } else if (y < topEdge + 44) {
    dy = -Math.min(18, Math.max(4, (((topEdge + 44) - y) / 44) * 14));
  }
  if (dy !== 0) {
    const prevTop = vhost.scrollTop;
    vhost.scrollTop = Math.max(0, Math.min(vhost.scrollHeight - vhost.clientHeight, prevTop + dy));
    if (vhost.scrollTop !== prevTop) {
      vUpdate();
      vReportMetrics();
      applyDocxHandlePoint(x, y);
    }
    docxAutoScrollRaf = requestAnimationFrame(tickDocxAutoScroll);
  }
}

function docxOnHandleStart(ev) {
  if (!docxEditMode || ev.touches.length !== 1) return;
  const t = ev.touches[0];

  // 1) 선택 손잡이(양쪽) 우선 확인
  if (docxSelRange && !docxSelRange.collapsed) {
    const handles = [...document.querySelectorAll('.eri-sel-handle')];
    let best = null, bestDist = 64;
    for (const h of handles) {
      const r = h.getBoundingClientRect();
      const cx = (r.left + r.right) * 0.5;
      const cy = r.top + 18;
      const d = Math.hypot(t.clientX - cx, t.clientY - cy);
      if (d <= bestDist) { bestDist = d; best = h; }
    }
    if (best) {
      ev.stopImmediatePropagation();
      ev.stopPropagation();
      ev.preventDefault();
      if (docxSelTimer) { clearTimeout(docxSelTimer); docxSelTimer = 0; }
      const side = best.dataset.side;
      docxLastPtNode = null;
      docxLastPtOff = -1;
      docxActiveHandleSide = side;
      docxCaretHandleDragging = false;
      document.body.classList.remove('eri-scrolling');
      docxHandleFixedPt = side === 'start'
        ? { node: docxSelRange.endContainer, offset: docxSelRange.endOffset }
        : { node: docxSelRange.startContainer, offset: docxSelRange.startOffset };
      return;
    }
  }

  // 2) 커서 밑 손잡이 확인 (물방울 노브 28px 반경만 잡아 커서 주변 글자 탭을 방해하지 않음)
  if ((!docxSelRange || docxSelRange.collapsed) && docxCursor && docxCaretHandleEl && docxCaretHandleEl.isConnected) {
    const r = docxCaretHandleEl.getBoundingClientRect();
    const cx = (r.left + r.right) * 0.5;
    const cy = r.top + 22;
    if (Math.hypot(t.clientX - cx, t.clientY - cy) <= 28) {
      ev.stopImmediatePropagation();
      ev.stopPropagation();
      ev.preventDefault();
      if (docxSelTimer) { clearTimeout(docxSelTimer); docxSelTimer = 0; }
      docxLastPtNode = null;
      docxLastPtOff = -1;
      docxCaretStartPt = { x: t.clientX, y: t.clientY };
      docxCaretMoved = false;
      docxCaretHandleDragging = true;
      docxActiveHandleSide = null;
      document.body.classList.remove('eri-scrolling');
      return;
    }
  }
}

function docxOnHandleMove(ev) {
  if ((!docxActiveHandleSide && !docxCaretHandleDragging) || !ev.touches.length) return;
  ev.stopImmediatePropagation();
  ev.stopPropagation();
  ev.preventDefault();
  const t = ev.touches[0];
  if (docxCaretHandleDragging && docxCaretStartPt && Math.hypot(t.clientX - docxCaretStartPt.x, t.clientY - docxCaretStartPt.y) >= 4) {
    docxCaretMoved = true;
  }
  docxAutoScrollPt = { x: t.clientX, y: t.clientY };
  if (vertical && vhost && !docxAutoScrollRaf) {
    const topEdge = 64;
    const botEdge = window.innerHeight - (docxKbInset > 0 ? docxKbInset + 72 : 48);
    if (t.clientY > botEdge - 68 || t.clientY < topEdge + 54) {
      docxAutoScrollRaf = requestAnimationFrame(tickDocxAutoScroll);
    }
  }
  docxDragPending = { x: t.clientX, y: t.clientY };
  if (docxDragRaf) return;
  docxDragRaf = requestAnimationFrame(() => {
    docxDragRaf = 0;
    const p = docxDragPending;
    docxDragPending = null;
    if (!p || (!docxActiveHandleSide && !docxCaretHandleDragging)) return;
    applyDocxHandlePoint(p.x, p.y);
  });
}

function docxOnHandleEnd(ev) {
  stopDocxAutoScroll();
  if (!docxActiveHandleSide && !docxCaretHandleDragging) return;
  docxCancelDragRaf();
  const wasCaret = docxCaretHandleDragging;
  docxActiveHandleSide = null;
  docxCaretHandleDragging = false;
  docxHandleFixedPt = null;
  docxSelJustEndedAt = Date.now();
  if (ev && ev.stopPropagation) ev.stopPropagation();
  docxLastPtNode = null;
  docxLastPtOff = -1;
  if (wasCaret) {
    if (!docxCaretMoved && docxCaretStartPt) {
      const tapPt = docxCaretPointAt(docxCaretStartPt.x, docxCaretStartPt.y);
      if (tapPt) docxCursor = { ...tapPt };
    }
    docxCaretStartPt = null;
    docxCaretMoved = false;
    docxRenderCaret();
  }
  docxFocusIme();
  docxEmitEditState(false);
}

function docxMountSelHandle(pageEl, side, relX, relY) {
  if (!pageEl) return;
  let h = docxHandleEls[side];
  if (!h) {
    h = document.createElement('div');
    h.className = 'eri-sel-handle';
    h.dataset.side = side;
    h.addEventListener('touchstart', (ev) => {
      if (ev.touches.length !== 1 || !docxSelRange) return;
      docxActiveHandleSide = side;
      docxHandleFixedPt = side === 'start'
        ? { node: docxSelRange.endContainer, offset: docxSelRange.endOffset }
        : { node: docxSelRange.startContainer, offset: docxSelRange.startOffset };
      ev.stopPropagation();
      ev.preventDefault();
    }, { passive: false });
    docxHandleEls[side] = h;
  }
  const cx = Math.max(1, Math.min(99, Number(relX) || 0));
  const cy = Math.max(1, Math.min(99, Number(relY) || 0));
  if (vertical && vinner) {
    const full = pageEl.closest?.('.vfull'), slot = pageEl.closest?.('.vslot') || pageEl;
    const box = full || slot, ox = full ? slot.offsetLeft + full.offsetLeft : slot.offsetLeft, oy = full ? slot.offsetTop + full.offsetTop : slot.offsetTop;
    const lx = ox + (cx / 100) * box.offsetWidth;
    const ly = oy + (cy / 100) * box.offsetHeight;
    h.style.left = `${lx}px`;
    h.style.top = `${ly}px`;
    if (h.parentNode !== vinner) vinner.appendChild(h);
  } else {
    h.style.left = `${cx}%`;
    h.style.top = `${cy}%`;
    if (h.parentNode !== pageEl) pageEl.appendChild(h);
  }
  h.style.marginLeft = '-24px';
  h.style.marginTop = '-2px';
  h.style.display = 'block';
  h.style.visibility = 'visible';
  h.style.opacity = '1';
  h.style.pointerEvents = 'auto';
  h.style.zIndex = '45';
}

// 고른 글 바탕: 쪽마다 따로 그려 두고(쪽 크기 대비 %), 고른 범위가 그 쪽 안에서 바뀐 쪽만 다시 그림
// (손잡이를 끌며 여러 쪽을 넘어갈 때 매번 모든 쪽을 지우고 다시 재면 한 장면에 수백 ms가 걸려 심하게 버벅였음)
const docxSelPages = new Map(); // 쪽(.page) → { key, els, first, last }
const docxNodeIds = new WeakMap();
let docxNodeSeq = 0;
function docxNodeId(n) {
  let id = docxNodeIds.get(n);
  if (!id) { id = ++docxNodeSeq; docxNodeIds.set(n, id); }
  return id;
}
/** 이 쪽에서 고른 범위가 어떻게 걸쳐 있는지 (같으면 다시 그릴 필요 없음) */
function docxSelPageKey(p, range) {
  const s = p.contains(range.startContainer) ? `${docxNodeId(range.startContainer)}:${range.startOffset}` : '<';
  const e = p.contains(range.endContainer) ? `${docxNodeId(range.endContainer)}:${range.endOffset}` : '>';
  return `${s}|${e}`;
}
/** 글 자리 하나의 화면 네모 (손잡이 자리) */
function docxPointRect(node, offset) {
  try {
    const len = (node.nodeValue || '').length;
    const r = document.createRange();
    const o = Math.max(0, Math.min(len, offset));
    // 글자 하나를 감싸 재면 줄 높이가 정확함 (빈 자리면 앞 글자)
    if (o < len) { r.setStart(node, o); r.setEnd(node, o + 1); const q = [...r.getClientRects()].find(x => x.height > 0); if (q) return { left: q.left, right: q.left, top: q.top, bottom: q.bottom }; }
    if (o > 0) { r.setStart(node, o - 1); r.setEnd(node, o); const q = [...r.getClientRects()].find(x => x.height > 0); if (q) return { left: q.right, right: q.right, top: q.top, bottom: q.bottom }; }
  } catch (_) {}
  return null;
}
/** 쪽 하나의 고른 바탕 네모들 (쪽 크기 대비 %) */
function docxSelPageRects(p, range) {
  const pr = p.getBoundingClientRect();
  if (!(pr.width > 0 && pr.height > 0)) return [];
  const pw = pr.width, ph = pr.height;
  const rawRects = [];
  const sub = document.createRange();
  const clipCache = new Map();
  for (const tn of docxPageTextNodes(p, docxValidPageTextNode)) {
    if (!range.intersectsNode(tn)) continue;
    const text = tn.nodeValue;
    let sOff = tn === range.startContainer ? range.startOffset : 0;
    let eOff = tn === range.endContainer ? range.endOffset : text.length;
    // 앞뒤 빈칸·탭은 칠하지 않음 (번호 매기기 탭이 쪽 왼쪽 끝까지 칠해져 보였음)
    while (sOff < eOff && /\s/.test(text[sOff])) sOff++;
    while (eOff > sOff && /\s/.test(text[eOff - 1])) eOff--;
    if (eOff <= sOff) continue;
    sub.setStart(tn, sOff);
    sub.setEnd(tn, eOff);
    // 보이는 영역(본문 상자)으로 자름: 다른 쪽 몫으로 옆에 밀려나 가려진 글은 칠하지 않음
    const clipEl = tn.parentElement.closest('.freader-content');
    let cq = clipCache.get(clipEl);
    if (cq === undefined) { cq = clipEl && p.contains(clipEl) ? clipEl.getBoundingClientRect() : null; clipCache.set(clipEl, cq); }
    const clipL = Math.max(pr.left, cq ? cq.left : pr.left), clipR = Math.min(pr.right, cq ? cq.right : pr.right);
    for (const r of sub.getClientRects()) {
      if (!(r.width > 0.5 && r.width < pw * 0.96 && r.height > 0.5 && r.height < 64)) continue;
      const cl = Math.max(clipL, r.left), cr = Math.min(clipR, r.right);
      // 쪽 밖(다른 쪽 몫으로 옆에 밀려나 있는 글)에 걸친 네모는 뺌 — 쪽 왼쪽 끝에 엉뚱한 바탕이 칠해졌음
      if (cr - cl > 0.5 && cr - cl >= r.width * 0.6) rawRects.push({ left: cl, right: cr, top: r.top, bottom: r.bottom, midY: (r.top + r.bottom) * 0.5 });
    }
  }
  rawRects.sort((a, b) => a.midY - b.midY || a.left - b.left);
  const merged = [];
  for (const r of rawRects) {
    const prev = merged.length > 0 ? merged[merged.length - 1] : null;
    const minH = prev ? Math.min(prev.bottom - prev.top, r.bottom - r.top) : 0;
    if (prev && Math.abs(r.midY - prev.midY) <= Math.max(3, minH * 0.45) && r.left <= prev.right + 28) {
      prev.left = Math.min(prev.left, r.left);
      prev.right = Math.max(prev.right, r.right);
      prev.top = Math.min(prev.top, r.top);
      prev.bottom = Math.max(prev.bottom, r.bottom);
      prev.midY = (prev.top + prev.bottom) * 0.5;
    } else {
      merged.push({ ...r });
    }
  }
  return merged.map(rc => ({
    l: ((rc.left - pr.left) / pw) * 100,
    t: ((rc.top - pr.top) / ph) * 100,
    w: (Math.max(2, rc.right - rc.left) / pw) * 100,
    h: (Math.max(8, rc.bottom - rc.top) / ph) * 100,
  }));
}
/** 고른 범위 끝 자리의 손잡이 위치 (그 쪽 크기 대비 %) */
function docxSelHandlePct(p, node, offset, side) {
  const q = docxPointRect(node, offset);
  if (!q) return null;
  const pr = p.getBoundingClientRect();
  if (!(pr.width > 0 && pr.height > 0)) return null;
  return { x: (((side === 'start' ? q.left : q.right) - pr.left) / pr.width) * 100, y: ((q.bottom - pr.top) / pr.height) * 100 };
}

function docxRenderSelection() {
  if (!docxEditMode || !docxSelRange || docxSelRange.collapsed) { docxClearSelectionOverlays(false); return; }
  docxRemoveCaret();
  const range = docxSelRange;
  try {
    const pageEls = [...document.querySelectorAll('#pages > .page, #vpages .page')].filter(p => !p.closest('#pages-under'));
    // 1) 재기: 바뀐 쪽만 (이때는 화면을 고치지 않아 한 번만 배치 계산)
    const plans = [];
    const seen = new Set();
    for (const p of pageEls) {
      if (!range.intersectsNode(p)) continue;
      seen.add(p);
      const key = docxSelPageKey(p, range);
      const old = docxSelPages.get(p);
      if (old && old.key === key) continue;
      const rects = docxSelPageRects(p, range);
      const first = p.contains(range.startContainer) ? docxSelHandlePct(p, range.startContainer, range.startOffset, 'start') : null;
      const last = p.contains(range.endContainer) ? docxSelHandlePct(p, range.endContainer, range.endOffset, 'end') : null;
      plans.push({ p, key, rects, first, last });
    }
    // 2) 그리기: 범위에서 빠진 쪽은 지우고, 바뀐 쪽만 새로
    for (const [p, c] of docxSelPages) {
      if (seen.has(p)) continue;
      for (const el of c.els) el.remove();
      docxSelPages.delete(p);
    }
    for (const plan of plans) {
      const old = docxSelPages.get(plan.p);
      const els = old ? old.els : [];
      while (els.length > plan.rects.length) els.pop().remove();
      plan.rects.forEach((rc, i) => {
        let box = els[i];
        if (!box) { box = document.createElement('div'); box.className = 'eri-docx-sel-rect'; plan.p.appendChild(box); els.push(box); }
        box.style.left = `${rc.l}%`;
        box.style.top = `${rc.t}%`;
        box.style.width = `${rc.w}%`;
        box.style.height = `${rc.h}%`;
      });
      docxSelPages.set(plan.p, { key: plan.key, els, first: plan.first, last: plan.last });
    }
    // 손잡이: 고른 범위의 맨 앞·맨 뒤 글자 자리 (그 쪽이 화면에 붙어 있을 때만)
    let start = null, end = null;
    for (const [p, c] of docxSelPages) {
      if (c.first) start = { p, ...c.first };
      if (c.last) end = { p, ...c.last };
    }
    if (start) docxMountSelHandle(start.p, 'start', start.x, start.y); else docxHideSelHandle('start');
    if (end) docxMountSelHandle(end.p, 'end', end.x, end.y); else docxHideSelHandle('end');
  } catch (_) {}
}
/** 고른 범위 끝이 붙어 있지 않은 쪽에 있으면 그 손잡이는 숨김 (끌고 있는 손잡이는 그대로) */
function docxHideSelHandle(side) {
  const h = docxHandleEls[side];
  if (h && docxActiveHandleSide !== side) h.style.display = 'none';
}

function docxReadStyleAt(node) {
  let bold = false, italic = false, underline = false, fontSizePt = 11, textColor = '#000000';
  const el = node && node.nodeType === 1 ? node : node?.parentElement;
  if (el) {
    try {
      const cs = getComputedStyle(el);
      const fw = parseInt(cs.fontWeight, 10);
      bold = cs.fontWeight === 'bold' || (Number.isFinite(fw) && fw >= 600);
      italic = cs.fontStyle === 'italic' || cs.fontStyle === 'oblique';
      const td = (cs.textDecorationLine || cs.textDecoration || '').toLowerCase();
      underline = td.includes('underline');
      const px = parseFloat(cs.fontSize);
      if (Number.isFinite(px) && px > 0) fontSizePt = Math.max(6, Math.min(48, Math.round(px * 0.75)));
      if (cs.color) textColor = docxRgbToHex(cs.color);
    } catch (_) {}
  }
  return {
    bold: docxPendingFmt.bold !== undefined ? Boolean(docxPendingFmt.bold) : bold,
    italic: docxPendingFmt.italic !== undefined ? Boolean(docxPendingFmt.italic) : italic,
    underline: docxPendingFmt.underline !== undefined ? Boolean(docxPendingFmt.underline) : underline,
    fontSizePt: docxPendingFmt.fontSizePt !== undefined ? Number(docxPendingFmt.fontSizePt) : fontSizePt,
    textColor: docxPendingFmt.textColor || textColor,
  };
}

function docxEmitEditState(typed = false) {
  const refNode = (docxSelRange && !docxSelRange.collapsed)
    ? docxSelRange.startContainer
    : (docxCursor ? docxCursor.node : null);
  const st = docxReadStyleAt(refNode);
  emit('editState', {
    canUndo: docxUndoStack.length > 0,
    canRedo: docxRedoStack.length > 0,
    dirty: docxEditDirty,
    bold: st.bold,
    italic: st.italic,
    underline: st.underline,
    fontSizePt: st.fontSizePt,
    textColor: st.textColor,
    hasCursor: Boolean(docxCursor || (docxSelRange && !docxSelRange.collapsed)),
    hasSelection: Boolean(docxSelRange && !docxSelRange.collapsed),
    typed: Boolean(typed),
  });
}

let docxReflowTimer = 0;
/** 고친 뒤 글이 늘거나 줄면 쪽 수와 쪽마다 보이는 자리를 다시 셈 (넘친 줄이 다음 쪽에 실제로 이어지게) */
function docxScheduleReflow() {
  if (docxReflowTimer) clearTimeout(docxReflowTimer);
  docxReflowTimer = setTimeout(() => {
    docxReflowTimer = 0;
    if (disposed) return;
    docxRecountPages(); // 쪽 수와 함께 덩어리 자리도 다시 잼
    vRefreshClones();
    // 되돌리기 등으로 되살린 글에는 예전 그림 주소가 들어 있을 수 있음 → 보이는 쪽 그림을 다시 채움
    if (vertical) { for (const m of vMounted.values()) if (m.original) void vLoadImages(m.frame, vSerial); }
    else for (const frame of realFrames()) void loadFrameImagesFresh(frame);
  }, 250);
}

function docxRecountPages() {
  if (!pages.length) return;
  const sources = [];
  for (const e of pages) if (!sources.includes(e.source)) sources.push(e.source);
  const result = [];
  for (const source of sources) {
    const first = pages.find(e => e.source === source);
    const inner = source.querySelector('.freader-columns');
    if (!inner || !first) { for (const e of pages) if (e.source === source) result.push(e); continue; }
    const columnGap = first.columnStride - first.bodyWidth;
    const columns = Math.max(1, Math.ceil((inner.scrollWidth + columnGap - 1) / first.columnStride));
    measureBlocks(source, inner, columns, first.columnStride);
    for (let column = 0; column < columns; column++) {
      const old = pages.find(e => e.source === source && e.column === column);
      result.push({ ...first, column, sectionPageCount: columns, images: old ? old.images : [] });
    }
  }
  if (result.length === pages.length) { pages = result; return; }
  const curEntry = pages[page];
  pages = result; outlineBlockCache = null;
  if (curEntry) {
    const at = pages.findIndex(e => e.source === curEntry.source && e.column === curEntry.column);
    if (at >= 0) page = at;
  }
  page = clampPage(page);
  if (vertical && vhost) {
    vLayout(true);
    if (docxEditMode && docxEditPage != null) {
      vAdoptOriginal(Math.min(docxEditPage, pages.length - 1));
      if (docxSelRange && !docxSelRange.collapsed) docxRenderSelection();
      else if (docxCursor) docxRenderCaret();
    }
  } else {
    // 지금 보이는 쪽 번호표만 맞춤 (원래 글 덩어리는 그대로 두어 커서가 끊기지 않게)
    for (const frame of host.querySelectorAll(':scope > .page')) {
      const idx = Number(frame.dataset.page);
      if (Number.isFinite(idx)) frame.setAttribute('aria-label', `${idx + 1} / ${pages.length}`);
    }
  }
  reportLocation();
}

function docxPushUndo() {
  docxScheduleReflow();
  const cur = docxSnapshotPages();
  if (docxLastSnap) {
    docxUndoStack.push(docxLastSnap);
    if (docxUndoStack.length > 40) docxUndoStack.shift();
  }
  docxLastSnap = cur;
  docxRedoStack = [];
  docxEditDirty = true;
}

function docxPreventContext(e) {
  if (!docxEditMode) return;
  e.preventDefault();
  e.stopPropagation();
}

function docxBuildWordRangeAt(pt) {
  if (!pt || !pt.node || !pt.node.isConnected) return null;
  const txt = pt.node.nodeValue || '';
  const len = txt.length;
  if (len === 0) return null;
  const idx = Math.max(0, Math.min(len - 1, pt.offset >= len ? len - 1 : pt.offset));
  const isWordChar = (ch) => ch && !/[\s.,!?;:()\[\]{}"'·•❖\-\/]/.test(ch);
  let l = idx, r = idx + 1;
  if (isWordChar(txt[idx])) {
    while (l > 0 && isWordChar(txt[l - 1])) l--;
    while (r < len && isWordChar(txt[r])) r++;
  }
  const range = document.createRange();
  range.setStart(pt.node, l);
  range.setEnd(pt.node, r);
  return range;
}

function docxOnTouchStart(e) {
  if (!docxEditMode || disposed || docxActiveHandleSide || docxCaretHandleDragging) return;
  if (e.target && e.target.closest && e.target.closest('.eri-sel-handle, .eri-caret-handle')) return;
  if (e.touches.length !== 1) {
    if (docxSelTimer) { clearTimeout(docxSelTimer); docxSelTimer = 0; }
    return;
  }
  const t = e.touches[0];
  docxSelDownX = t.clientX;
  docxSelDownY = t.clientY;
  docxAdoptAt(t.clientX, t.clientY);
  if (docxSelTimer) { clearTimeout(docxSelTimer); docxSelTimer = 0; }
  // 한 단어를 길게 누르면 단어 전체 하이라이트 + 양쪽 손잡이 표시 (영역 확장은 손잡이로만)
  docxSelTimer = setTimeout(() => {
    docxSelTimer = 0;
    const pt = docxCaretPointAt(docxSelDownX, docxSelDownY);
    if (!pt) return;
    const wr = docxBuildWordRangeAt(pt);
    if (!wr || wr.collapsed) return;
    docxSelDragging = false;
    docxSelAnchorPt = null;
    docxSelJustEndedAt = Date.now();
    docxCursor = { node: wr.endContainer, offset: wr.endOffset };
    docxSelRange = wr;
    docxRenderSelection();
    docxEmitEditState(false);
  }, 300);
}

function docxOnTouchMove(e) {
  if (!docxEditMode || disposed) return;
  if (e.touches.length !== 1) {
    if (docxSelTimer) { clearTimeout(docxSelTimer); docxSelTimer = 0; }
    return;
  }
  const t = e.touches[0];
  if (docxSelTimer && Math.hypot(t.clientX - docxSelDownX, t.clientY - docxSelDownY) > 14) {
    clearTimeout(docxSelTimer);
    docxSelTimer = 0;
  }
}

function docxOnTouchEnd() {
  if (docxSelTimer) { clearTimeout(docxSelTimer); docxSelTimer = 0; }
  if (docxSelRange && !docxSelRange.collapsed && Date.now() - docxSelJustEndedAt < 800) {
    docxSelJustEndedAt = Date.now();
  }
}

let docxEditPage = null; // 스크롤 보기에서 지금 고치고 있는 쪽 (원래 글 덩어리를 쓰는 쪽)
/** 스크롤 보기: 손가락이 닿은 쪽이 복사본이면 원래 글 덩어리로 바꿔 둠 (고친 글이 저장되게) */
function docxAdoptAt(x, y) {
  if (!vertical || !vhost) return;
  const slot = document.elementFromPoint(x, y)?.closest?.('.vslot');
  if (!slot) return;
  const index = Number(slot.dataset.page);
  if (!Number.isFinite(index)) return;
  const m = vMounted.get(index);
  docxEditPage = index;
  if (!m || m.original) return;
  // 다른 쪽에 잡혀 있는 커서·선택은 원래 덩어리를 따라 옮겨 가므로 비움
  docxSelRange = null;
  docxClearSelectionOverlays();
  docxRemoveCaret();
  vAdoptOriginal(index);
}

function docxOnClick(e) {
  if (!docxEditMode || disposed) return;
  if (e.target && e.target.closest && e.target.closest('.eri-sel-handle, .eri-caret-handle')) return;
  if (Date.now() - docxSelJustEndedAt < 650) return;
  // 더블탭 기본 선택 완전 차단 + 단일 커서만 깔끔하게 배치 (손잡이 없음)
  try { window.getSelection()?.removeAllRanges(); } catch (_) {}
  docxAdoptAt(e.clientX, e.clientY);
  const pt = docxCaretPointAt(e.clientX, e.clientY);
  if (!pt) return;
  docxSelRange = null;
  docxClearSelectionOverlays();
  docxPendingFmt = {};
  docxCursor = { ...pt };
  docxImeComposing = false;
  docxImeCompLen = 0;
  docxImeCompNode = null;
  docxRenderCaret();
  docxFocusIme();
  docxEmitEditState(false);
}

function docxOnDblClick(e) {
  if (!docxEditMode) return;
  e.preventDefault();
  e.stopPropagation();
  try { window.getSelection()?.removeAllRanges(); } catch (_) {}
}

function setKeyboardInset(px) {
  docxKbInset = Math.max(0, Number(px) || 0);
  if (vinner) {
    vinner.style.paddingBottom = docxKbInset > 0 ? `${docxKbInset + 80}px` : '';
  }
  if (docxKbInset === 0 && vertical && vhost) {
    const maxTop = Math.max(0, vhost.scrollHeight - vhost.clientHeight);
    if (vhost.scrollTop > maxTop) vhost.scrollTop = maxTop;
    vUpdate();
    vReportMetrics();
  }
  return docxKbInset;
}

function setEditMode(enabled) {
  docxEditMode = Boolean(enabled);
  document.body.classList.toggle('eri-docx-edit', docxEditMode);
  if (docxEditMode) {
    lastHostW = host ? host.clientWidth : 0;
    lastVHostW = vhost ? vhost.clientWidth : 0;
    docxEditOrigHtml = docxSnapshotPages();
    docxOrigParas = new Map();
    for (const [idx, els] of docxParaGroups()) docxOrigParas.set(idx, docxParaState(els));
    docxUndoStack = [];
    docxRedoStack = [];
    docxLastSnap = docxSnapshotPages();
    docxEditDirty = false;
    docxCursor = null;
    docxSelRange = null;
    docxPendingFmt = {};
    docxEnsureIme();
    document.addEventListener('contextmenu', docxPreventContext, true);
    document.addEventListener('dblclick', docxOnDblClick, true);
    document.addEventListener('mousedown', docxPreventBlurMouseDown, true);
    document.addEventListener('touchstart', docxOnHandleStart, { passive: false, capture: true });
    document.addEventListener('touchstart', docxOnTouchStart, { passive: true, capture: true });
    document.addEventListener('touchmove', docxOnHandleMove, { passive: false, capture: true });
    document.addEventListener('touchend', docxOnHandleEnd, { passive: true, capture: true });
    document.addEventListener('touchcancel', docxOnHandleEnd, { passive: true, capture: true });
    document.addEventListener('touchmove', docxOnTouchMove, { passive: false, capture: true });
    document.addEventListener('touchend', docxOnTouchEnd, { passive: true, capture: true });
    document.addEventListener('touchcancel', docxOnTouchEnd, { passive: true, capture: true });
    document.addEventListener('click', docxOnClick, true);
    docxEmitEditState(false);
  } else {
    if (docxSelTimer) { clearTimeout(docxSelTimer); docxSelTimer = 0; }
    docxSelDragging = false;
    docxSelAnchorPt = null;
    docxSelRange = null;
    docxCursor = null;
    docxPendingFmt = {};
    docxRemoveCaret();
    docxClearSelectionOverlays();
    document.removeEventListener('contextmenu', docxPreventContext, true);
    document.removeEventListener('dblclick', docxOnDblClick, true);
    docxCancelDragRaf();
    stopDocxAutoScroll();
    docxCaretHandleDragging = false;
    docxActiveHandleSide = null;
    docxHandleFixedPt = null;
    document.removeEventListener('mousedown', docxPreventBlurMouseDown, true);
    document.removeEventListener('touchstart', docxOnHandleStart, true);
    document.removeEventListener('touchstart', docxOnTouchStart, true);
    document.removeEventListener('touchmove', docxOnHandleMove, true);
    document.removeEventListener('touchend', docxOnHandleEnd, true);
    document.removeEventListener('touchcancel', docxOnHandleEnd, true);
    document.removeEventListener('touchmove', docxOnTouchMove, true);
    document.removeEventListener('touchend', docxOnTouchEnd, true);
    document.removeEventListener('touchcancel', docxOnTouchEnd, true);
    document.removeEventListener('click', docxOnClick, true);
    if (docxImeEl) {
      docxImeEl.value = '';
      docxImeEl.blur();
      docxImeEl.disabled = true;
      docxImeEl.style.display = 'none';
    }
    setKeyboardInset(0);
    if (vertical && vhost) {
      if (vinner) vinner.style.paddingBottom = '';
      const maxTop = Math.max(0, vhost.scrollHeight - vhost.clientHeight);
      if (maxTop <= 1 || vhost.scrollTop > maxTop) vhost.scrollTop = Math.min(vhost.scrollTop, maxTop);
      vUpdate();
      vReportMetrics();
    }
    docxUndoStack = [];
    docxRedoStack = [];
    docxLastSnap = null;
  }
  return docxEditMode;
}

function docxApplyStyleToRange(range, opts) {
  if (!range || range.collapsed) return false;
  const root = range.commonAncestorContainer.nodeType === 1
    ? range.commonAncestorContainer
    : range.commonAncestorContainer.parentElement;
  if (!root) return false;

  const textNodes = [];
  const tw = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let cur = tw.nextNode();
  while (cur) {
    if ((cur.nodeValue || '').length > 0 && range.intersectsNode(cur)) {
      textNodes.push(cur);
    }
    cur = tw.nextNode();
  }
  if (textNodes.length === 0) return false;

  let firstSpan = null, lastSpan = null;
  for (const tn of textNodes) {
    let target = tn;
    let startOff = 0;
    let endOff = target.nodeValue.length;
    if (tn === range.startContainer) startOff = range.startOffset;
    if (tn === range.endContainer) endOff = range.endOffset;
    if (endOff <= startOff) continue;
    if (endOff < target.nodeValue.length) target.splitText(endOff);
    if (startOff > 0) target = target.splitText(startOff);
    // CSS에서 부모 <span>의 text-decoration: underline은 자식의 none으로 지워지지 않으므로,
    // 밑줄 해제 시 조상 <span>의 밑줄을 직접 해제하고, 단일 자식 <span>은 중첩 대신 재사용함
    if (opts.underline === false) {
      let anc = target.parentElement;
      while (anc && anc !== root && anc.tagName === 'SPAN') {
        const td = (anc.style.textDecoration || anc.style.textDecorationLine || '').toLowerCase();
        if (td.includes('underline')) {
          anc.style.textDecoration = 'none';
          anc.style.textDecorationLine = 'none';
        }
        anc = anc.parentElement;
      }
    }
    let span;
    if (target.parentElement && target.parentElement.tagName === 'SPAN' && target.parentElement.childNodes.length === 1) {
      span = target.parentElement;
    } else {
      span = document.createElement('span');
      span.dataset.eriFmt = '1';
      target.parentNode.insertBefore(span, target);
      span.appendChild(target);
    }
    if (opts.bold !== undefined) span.style.fontWeight = opts.bold ? 'bold' : 'normal';
    if (opts.italic !== undefined) span.style.fontStyle = opts.italic ? 'italic' : 'normal';
    if (opts.underline !== undefined) {
      span.style.textDecoration = opts.underline ? 'underline' : 'none';
      span.style.textDecorationLine = opts.underline ? 'underline' : 'none';
    }
    if (opts.fontSizePt !== undefined) {
      const pt = Math.max(6, Math.min(48, Number(opts.fontSizePt) || 11));
      span.style.fontSize = `${pt}pt`;
      span.style.lineHeight = '1.45';
      const paraEl = span.closest?.('x-p, p');
      if (paraEl) {
        const curLh = parseFloat(getComputedStyle(paraEl).lineHeight);
        if (Number.isFinite(curLh) && curLh < pt * 1.45 * 1.333) {
          paraEl.style.lineHeight = '1.45';
        }
      }
    }
    if (opts.textColor !== undefined) span.style.color = String(opts.textColor);
    if (!firstSpan) firstSpan = span;
    lastSpan = span;
  }
  if (firstSpan && lastSpan) {
    const nr = document.createRange();
    nr.setStart(firstSpan.firstChild, 0);
    nr.setEnd(lastSpan.firstChild, lastSpan.firstChild.nodeValue.length);
    docxSelRange = nr;
    return true;
  }
  return false;
}

function editApplyFormat(opts) {
  if (!docxEditMode || disposed || !opts) return false;
  if (opts.bold !== undefined) docxPendingFmt.bold = Boolean(opts.bold);
  if (opts.italic !== undefined) docxPendingFmt.italic = Boolean(opts.italic);
  if (opts.underline !== undefined) docxPendingFmt.underline = Boolean(opts.underline);
  if (opts.fontSizePt !== undefined) docxPendingFmt.fontSizePt = Number(opts.fontSizePt);
  if (opts.textColor !== undefined) docxPendingFmt.textColor = String(opts.textColor);

  if (docxSelRange && !docxSelRange.collapsed) {
    if (docxApplyStyleToRange(docxSelRange, opts)) {
      docxPushUndo();
      docxClearSelectionOverlays(true);
      docxRenderSelection();
    }
  } else {
    // 커서만 둔 상태에서 서식 변경 시 진행 중이던 한글 조합 끊기 (중복 입력 방지)
    docxSuppressImeReset = true;
    docxImeComposing = false;
    docxImeCompLen = 0;
    docxImeCompNode = null;
    if (docxImeEl) {
      docxImeEl.blur();
      docxResetImeBuffer();
      try { docxImeEl.focus({ preventScroll: true }); } catch (_) {}
    }
    setTimeout(() => { docxSuppressImeReset = false; }, 80);
  }
  docxEmitEditState(false);
  return true;
}

function editUndo() {
  if (!docxEditMode || docxUndoStack.length === 0) return false;
  const prev = docxUndoStack.pop();
  if (docxLastSnap) docxRedoStack.push(docxLastSnap);
  docxLastSnap = prev;
  docxApplySnapshot(prev);
  docxScheduleReflow();
  docxSelRange = null;
  docxCursor = null;
  docxRemoveCaret();
  docxClearSelectionOverlays();
  docxEditDirty = docxUndoStack.length > 0;
  docxEmitEditState(false);
  return true;
}

function editRedo() {
  if (!docxEditMode || docxRedoStack.length === 0) return false;
  const next = docxRedoStack.pop();
  if (docxLastSnap) docxUndoStack.push(docxLastSnap);
  docxLastSnap = next;
  docxApplySnapshot(next);
  docxScheduleReflow();
  docxSelRange = null;
  docxCursor = null;
  docxRemoveCaret();
  docxClearSelectionOverlays();
  docxEditDirty = true;
  docxEmitEditState(false);
  return true;
}

function cancelEditSession() {
  if (docxEditOrigHtml.length > 0) {
    docxApplySnapshot(docxEditOrigHtml);
    docxScheduleReflow();
  }
  docxEditDirty = false;
  setEditMode(false);
  return true;
}

/** 원본 문단 번호별로 지금 화면의 문단 조각들을 모음 (쪽 나눔으로 나뉜 조각은 같은 번호) */
function docxParaGroups() {
  const groups = new Map();
  for (const src of docxUniqueSources()) {
    for (const el of src.querySelectorAll('x-p[data-eri-pi]')) {
      if (el.closest('.docx-note-area')) continue;
      const idx = Number(el.dataset.eriPi);
      if (!Number.isFinite(idx)) continue;
      let g = groups.get(idx);
      if (!g) groups.set(idx, g = []);
      g.push(el);
    }
  }
  return groups;
}

/** 문단에 들어 있는 글자를 차례로 훑음 (목록 번호·안쪽 문단·편집 표시는 뺌) */
function docxWalkPara(els, onText, onBreak) {
  const walk = (node, root) => {
    if (node.nodeType === 3) {
      const text = node.nodeValue || '';
      if (text) onText(text, node);
      return;
    }
    if (node.nodeType !== 1) return;
    if (node !== root && node.matches && node.matches('x-p[data-eri-pi], .odr-list-marker, .docx-note-area, .eri-docx-caret, .eri-caret-handle, .eri-sel-handle, .eri-docx-sel-rect, .eri-copy-mark')) return;
    if (node.tagName === 'BR') {
      // 빈 문단 자리를 지키려고 넣은 끝 줄바꿈은 글자가 아님
      if (node.parentElement === root && !docxHasTextAfter(node)) return;
      onBreak();
      return;
    }
    for (const child of node.childNodes) walk(child, root);
  };
  for (const el of els) walk(el, el);
}

function docxHasTextAfter(node) {
  for (let n = node.nextSibling; n; n = n.nextSibling) {
    if ((n.textContent || '').length > 0) return true;
    if (n.nodeType === 1 && n.tagName === 'BR') return true;
  }
  return false;
}

function docxParaState(els) {
  let text = '';
  docxWalkPara(els, (t) => { text += t; }, () => { text += '\n'; });
  let fmt = '', imgs = 0;
  for (const el of els) {
    for (const sp of el.querySelectorAll('span[data-eri-fmt]')) fmt += sp.getAttribute('style') || '';
    imgs += el.querySelectorAll('img').length;
  }
  return { text: text.replace(/​/g, ''), fmt, imgs };
}

function docxCollectRuns(els) {
  const runs = [];
  docxWalkPara(els, (rawText, node) => {
    const text = rawText.replace(/​/g, '');
    if (!text) return;
    const parent = node.parentElement || els[0];
    const cs = getComputedStyle(parent);
    const fw = parseInt(cs.fontWeight, 10);
    const bold = cs.fontWeight === 'bold' || (Number.isFinite(fw) && fw >= 600);
    const italic = cs.fontStyle === 'italic' || cs.fontStyle === 'oblique';
    const td = (cs.textDecorationLine || cs.textDecoration || '').toLowerCase();
    const underline = td.includes('underline');
    const px = parseFloat(cs.fontSize);
    const fontSizePt = Number.isFinite(px) && px > 0 ? Math.round(px * 0.75 * 10) / 10 : null;
    const colorHex = docxRgbToHex(cs.color);
    const prev = runs.length > 0 ? runs[runs.length - 1] : null;
    if (prev && prev.bold === bold && prev.italic === italic && prev.underline === underline && prev.fontSizePt === fontSizePt && prev.colorHex === colorHex) {
      prev.text += text;
    } else {
      runs.push({ text, bold, italic, underline, fontSizePt, colorHex });
    }
  }, () => {
    if (runs.length > 0) runs[runs.length - 1].text += '\n';
    else runs.push({ text: '\n', bold: false, italic: false, underline: false, fontSizePt: null, colorHex: '#000000' });
  });
  return runs;
}

/**
 * 바뀐 문단만 원본 문단 번호와 함께 넘김
 * - 지워진 문단: deleted
 * - 글자만 바뀐 문단: 원래 글자(origText)와 새 글자(text) → 원본 서식을 살린 채 바뀐 부분만 고침
 * - 글자 서식을 바꾼 문단: runs(글자 덩어리별 서식)까지 넘김
 */
function exportEditedBytes() {
  if (!docxEditDirty) return { ok: true, dirty: false };
  const groups = docxParaGroups();
  const edits = [];
  for (const [idx, orig] of docxOrigParas) {
    const els = groups.get(idx);
    if (!els || els.length === 0) {
      edits.push({ index: idx, origText: orig.text, deleted: true });
      continue;
    }
    const cur = docxParaState(els);
    if (cur.text === orig.text && cur.fmt === orig.fmt) continue;
    const fmt = cur.fmt !== orig.fmt && cur.fmt.length > 0;
    edits.push({ index: idx, origText: orig.text, text: cur.text, fmt, runs: fmt ? docxCollectRuns(els) : [] });
  }
  return { ok: true, dirty: edits.length > 0, kind: 'docx_edits', edits };
}

window.freaderDocx = { setView, resetScrollZoom: vResetZoom, setScrollMarks, setCopyMarks, setScrollMemos, setScrollMemo, visibleSlots: vVisibleSlots, mostVisiblePage: vMostVisible, highlightBoxes: withoutZoom(highlightBoxes), beginDocument, appendChunk, openDocument, configure, display, next, previous, progress, highlightSelection: withoutZoom(highlightSelection), destroy, setVertical, scrollToRatio: vScrollToRatio, scrollByPx: (dy) => { if (!vhost) return false; vhost.scrollTop = Math.max(0, Math.min(vhost.scrollHeight - vhost.clientHeight, vhost.scrollTop + (Number(dy) || 0))); vUpdate(); vReportMetrics(); return true; }, setEditMode, editApplyFormat, editUndo, editRedo, cancelEditSession, setKeyboardInset, exportEditedBytes,
  search, showSearchResult, clearSearch, headingCandidates, pageText, visibleTextBoxes: withoutZoom(visibleTextBoxes), pageRect: withoutZoom(pageRect), pageSizes,
  getState: () => ({ ready, page, count: pages.length, received, spread: options.spread, awaitingPassword, unavailableImages, imageCacheBytes, cachedImages: imageCache.size, visibleImages: activeImagePaths.size, maxBytes: MAX_BYTES, format: detectedFormat }) };
window.addEventListener('pagehide', destroy, { once: true });
