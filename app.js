/* Warm Media — app.js
   ضع بيانات مشروع Supabase في CONFIG أدناه. لا تضع service_role key في المتصفح مطلقًا. */
const CONFIG = {
  SUPABASE_URL: "https://YOUR-PROJECT.supabase.co",
  SUPABASE_ANON_KEY: "YOUR_SUPABASE_ANON_KEY"
};

const $ = (id) => document.getElementById(id);
const validConfig = CONFIG.SUPABASE_URL.startsWith("https://") &&
  !CONFIG.SUPABASE_URL.includes("YOUR-PROJECT") &&
  CONFIG.SUPABASE_ANON_KEY && !CONFIG.SUPABASE_ANON_KEY.includes("YOUR_");

let supabase = null;
if (validConfig && window.supabase) {
  supabase = window.supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });
}

const THEME_KEY = "warm-media-theme";
const THEMES = ["dark", "light", "red"];
function applyTheme(theme, save = true) {
  if (!THEMES.includes(theme)) theme = "dark";
  document.body.dataset.theme = theme;
  document.documentElement.style.colorScheme = theme === "light" ? "light" : "dark";
  if (save) localStorage.setItem(THEME_KEY, theme);
  if (supabase) savePreference({ theme }).catch(() => {});
}
function savePreference(value) {
  if (!supabase) return Promise.resolve();
  return supabase.auth.getUser().then(async ({ data }) => {
    if (!data.user) return;
    await supabase.from("user_preferences").upsert({
      user_id: data.user.id, settings: value, updated_at: new Date().toISOString()
    }, { onConflict: "user_id" });
  });
}
applyTheme(localStorage.getItem(THEME_KEY) || "dark", false);

$("themeToggle")?.addEventListener("click", () => {
  const current = document.body.dataset.theme || "dark";
  const next = THEMES[(THEMES.indexOf(current) + 1) % THEMES.length];
  const wipe = $("themeWipe");
  wipe.style.setProperty("--wipe-color", next === "light" ? "#f4f6fb" : next === "red" ? "#e20e2c" : "#090c15");
  wipe.classList.remove("run");
  void wipe.offsetWidth;
  wipe.classList.add("run");
  const switchTheme = () => applyTheme(next);
  if (document.startViewTransition && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
    document.startViewTransition(switchTheme);
  } else {
    setTimeout(switchTheme, 180);
  }
});

const drawer = $("mobileDrawer"), overlay = $("mobileOverlay");
function closeDrawer(){ drawer?.classList.remove("open"); overlay?.classList.remove("open"); }
$("openMenu")?.addEventListener("click",()=>{drawer?.classList.add("open");overlay?.classList.add("open");});
$("closeMenu")?.addEventListener("click",closeDrawer);
overlay?.addEventListener("click",closeDrawer);
drawer?.querySelectorAll("a").forEach(a=>a.addEventListener("click",closeDrawer));
document.addEventListener("keydown",e=>{if(e.key==="Escape"){closeDrawer();$("authPanel")?.classList.remove("open");}});

function showStatus(message, isError=false) {
  const el = $("authStatus");
  if (el) { el.textContent = message; el.style.color = isError ? "#ff6573" : "var(--mut)"; }
}
$("closeAuth")?.addEventListener("click",()=>$("authPanel").classList.remove("open"));

async function authAction(action) {
  if (!supabase) return showStatus("أضف رابط Supabase ومفتاح anon في app.js أولًا.", true);
  const email = $("authEmail").value.trim(), password = $("authPassword").value;
  if (!email || password.length < 8) return showStatus("أدخل بريدًا صحيحًا وكلمة مرور من 8 أحرف على الأقل.", true);
  const result = action === "signup"
    ? await supabase.auth.signUp({ email, password })
    : await supabase.auth.signInWithPassword({ email, password });
  if (result.error) return showStatus(result.error.message, true);
  showStatus(action === "signup" ? "تم إرسال رسالة تأكيد إذا كان التحقق بالبريد مفعّلًا." : "تم تسجيل الدخول بنجاح.");
}
$("signIn")?.addEventListener("click",()=>authAction("signin"));
$("signUp")?.addEventListener("click",()=>authAction("signup"));

async function loadSiteSettings() {
  if (!supabase) return;
  const { data, error } = await supabase.from("site_settings").select("setting_key,setting_value");
  if (error) { console.warn("تعذر تحميل إعدادات الموقع:", error.message); return; }
  const settings = Object.fromEntries((data || []).map(x=>[x.setting_key,x.setting_value]));
  if (settings.site_name) document.title = settings.site_name;
  if (settings.typography?.font) {
    const allowed = ["Alexandria","Cairo","Tajawal","IBM Plex Sans Arabic","Noto Sans Arabic","Almarai","Changa","Readex Pro","Rubik","Somar Sans"];
    if (allowed.includes(settings.typography.font)) document.documentElement.style.setProperty("--font-ar", `"${settings.typography.font}",Tahoma,sans-serif`);
  }
  if (settings.theme_default && !localStorage.getItem(THEME_KEY)) applyTheme(settings.theme_default, false);
  if (settings.advertisement?.enabled && settings.advertisement?.text) {
    $("adText").textContent = settings.advertisement.text;
    $("adLink").href = settings.advertisement.url || "#";
    $("adSlot").classList.add("active");
  }
}
$("closeAd")?.addEventListener("click",()=>$("adSlot")?.classList.remove("active"));

async function loadNews() {
  const feed = $("newsFeed");
  if (!supabase) return;
  feed.innerHTML = '<div class="status">جاري تحميل الأخبار…</div>';
  const { data, error } = await supabase.from("news")
    .select("id,title,excerpt,image_url,category,is_breaking,published_at")
    .eq("status","published").order("published_at",{ascending:false}).range(0,8);
  if (error) {
    feed.innerHTML = '<div class="status">تعذر تحميل الأخبار. راجع إعدادات Supabase والصلاحيات.</div>';
    console.warn(error); return;
  }
  if (!data?.length) { feed.innerHTML = '<div class="status">لا توجد أخبار منشورة حاليًا.</div>'; return; }
  feed.replaceChildren(...data.map(item=>{
    const card=document.createElement("article"); card.className="news-card";
    if(item.image_url){const img=document.createElement("img");img.loading="lazy";img.decoding="async";img.src=item.image_url;img.alt=item.title;card.append(img);}
    const badge=document.createElement("span");badge.className="pill";badge.textContent=item.is_breaking?"عاجل":(item.category||"أخبار");card.append(badge);
    const title=document.createElement("h3");title.textContent=item.title;card.append(title);
    const excerpt=document.createElement("p");excerpt.textContent=item.excerpt||"";card.append(excerpt);
    return card;
  }));
}

async function init() {
  if (!supabase) {
    console.info("Supabase غير مضبوط بعد. الواجهة تعمل محليًا، والبيانات الحية تحتاج إعداد الاتصال.");
    return;
  }
  await Promise.all([loadSiteSettings(), loadNews()]);
  supabase.channel("warm-media-news")
    .on("postgres_changes",{event:"*",schema:"public",table:"news",filter:"status=eq.published"},()=>loadNews())
    .subscribe();
}
init();
