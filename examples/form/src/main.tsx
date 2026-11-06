import { StrictMode, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { installPreviewBridge } from "@ui-atlas/preview-bridge";
import catalog from "../../../catalog.json";
import "./style.css";

installPreviewBridge(new URL(catalog.shell.url).origin);

type Category = "Branding" | "Digital" | "Objects";
type Idea = {
  id: number;
  title: string;
  category: Category;
  author: string;
  art: string;
  description: string;
};
const categoryLabels: Record<Category, string> = {
  Branding: "品牌视觉",
  Digital: "数字设计",
  Objects: "器物设计",
};
const filterLabels: Record<string, string> = {
  "All ideas": "全部灵感",
  ...categoryLabels,
  Saved: "已收藏",
};
const initialIdeas: Idea[] = [
  {
    id: 1,
    title: "静物之美，形有所思",
    category: "Objects",
    author: "留白工作室",
    art: "objects",
    description:
      "以平衡的构图、温润的材质，探索留一点余地的美。这些雕塑般的造型完全由 CSS 绘制。",
  },
  {
    id: 2,
    title: "平凡日常里的魔法",
    category: "Branding",
    author: "日常出版社",
    art: "poster",
    description:
      "一套让人看见日常不凡之处的出版品牌视觉：温暖的红色、鲜明的衬线字体，再留一点玩心。",
  },
  {
    id: 3,
    title: "慢度：少一点，好一点",
    category: "Digital",
    author: "形态实验室",
    art: "banking",
    description:
      "一次小小的仪表盘设计探索。柔和的层次、讲究的留白与一抹鲜明的强调色，让复杂的产品也能从容呈现。",
  },
  {
    id: 4,
    title: "与美好相伴",
    category: "Branding",
    author: "原野手记",
    art: "company",
    description:
      "围绕相聚、成长与共鸣展开的品牌视觉，以清新的绿色搭配富有表现力的大字，传达彼此靠近的温度。",
  },
  {
    id: 5,
    title: "让界面柔和一点",
    category: "Digital",
    author: "星期日事务所",
    art: "weather",
    description:
      "一款温柔的天气界面，为慢一点的清晨留出空间。插画由渐变与简单图形在本地绘制。",
  },
  {
    id: 6,
    title: "停一停的艺术",
    category: "Objects",
    author: "离线工作室",
    art: "pause",
    description:
      "以拱形与光线探索温暖而可感的质地。这是一组想象中的器物，为忙碌之间的片刻而作。",
  },
];
const iconPaths: Record<string, string> = {
  plus: "M12 5v14M5 12h14",
  arrow: "M5 12h14m-5-5 5 5-5 5",
  bookmark: "M6 3h12v18l-6-4-6 4V3Z",
  search: "M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14Zm5 12 6 6",
  close: "m6 6 12 12M6 18 18 6",
  star: "m12 3 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2L12 17.3l-5.6 2.9 1.1-6.2L3 9.6l6.2-.9L12 3Z",
  check: "m5 12 4 4L19 6",
};
function Icon({
  name,
  size = 18,
  filled = false,
}: {
  name: string;
  size?: number;
  filled?: boolean;
}) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill={filled ? "currentColor" : "none"}
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={iconPaths[name] || iconPaths.arrow} />
    </svg>
  );
}
function Art({ kind }: { kind: string }) {
  if (kind === "objects")
    return (
      <div className="art art-objects" aria-hidden="true">
        <span className="art-caption">日常器物 / 第 01 号</span>
        <div className="object-shadow" />
        <div className="vase vase-one" />
        <div className="vase vase-two" />
        <div className="object-ball" />
        <span className="art-foot">静谧习作</span>
      </div>
    );
  if (kind === "poster")
    return (
      <div className="art art-poster" aria-hidden="true">
        <span className="poster-top">日常出版社</span>
        <span className="poster-type">
          平凡日常
          <br />
          也有<i>魔法。</i>
        </span>
        <span className="poster-flower">✳</span>
        <span className="poster-foot">美好就在我们身边。</span>
      </div>
    );
  if (kind === "banking")
    return (
      <div className="art art-banking" aria-hidden="true">
        <div className="bank-window">
          <div className="bank-sidebar">
            <b>慢</b>
            <i />
            <i />
            <i />
            <i />
          </div>
          <div className="bank-main">
            <span>
              早上好，小安 <b>↗</b>
            </span>
            <div className="bank-cards">
              <div>
                <small>总余额</small>
                <strong>
                  $12,840<span>.00</span>
                </strong>
                <em>↗ 本月增长 12.8%</em>
              </div>
              <div className="bank-purple">
                <small>你的卡片</small>
                <strong>慢度</strong>
                <em>•••• 4820</em>
              </div>
            </div>
            <div className="bank-chart">
              <span>月度概览</span>
              <div>
                {[28, 46, 34, 65, 52, 80, 61, 90, 72, 57, 77, 95].map(
                  (height, index) => (
                    <i key={index} style={{ height: `${height}%` }} />
                  ),
                )}
              </div>
            </div>
          </div>
        </div>
      </div>
    );
  if (kind === "company")
    return (
      <div className="art art-company" aria-hidden="true">
        <span className="company-small">让美好慢慢生长。</span>
        <span className="company-title">
          美好
          <br />
          <i>相伴。</i>
        </span>
        <span className="company-ring ring-one" />
        <span className="company-ring ring-two" />
        <span className="company-foot">多一点彼此相伴。</span>
      </div>
    );
  if (kind === "weather")
    return (
      <div className="art art-weather" aria-hidden="true">
        <div className="weather-sun" />
        <div className="weather-cloud" />
        <div className="weather-ui">
          <span>在某处，慢慢来。</span>
          <strong>
            22<span>°</span>
          </strong>
          <span>给今天添一缕阳光。</span>
          <div>
            <i>
              周一
              <br />
              <b>21°</b>
            </i>
            <i>
              周二
              <br />
              <b>23°</b>
            </i>
            <i>
              周三
              <br />
              <b>22°</b>
            </i>
            <i>
              周四
              <br />
              <b>20°</b>
            </i>
          </div>
        </div>
      </div>
    );
  return (
    <div className="art art-pause" aria-hidden="true">
      <span className="pause-top">离线生活系列</span>
      <div className="pause-arch" />
      <div className="pause-orb" />
      <span className="pause-type">
        不妨
        <br />
        <i>停一停。</i>
      </span>
      <span className="pause-foot">少一点匆忙，多一点余地。</span>
    </div>
  );
}
function App() {
  const [ideas, setIdeas] = useState(initialIdeas);
  const [filter, setFilter] = useState("All ideas");
  const [query, setQuery] = useState("");
  const [saved, setSaved] = useState<number[]>([2, 4]);
  const [selected, setSelected] = useState<Idea | null>(null);
  const [newTitle, setNewTitle] = useState("");
  const [newCategory, setNewCategory] = useState<Category>("Digital");
  const [formError, setFormError] = useState("");
  const detailDialog = useRef<HTMLDialogElement>(null);
  const addDialog = useRef<HTMLDialogElement>(null);
  const aboutDialog = useRef<HTMLDialogElement>(null);
  const newTitleInput = useRef<HTMLInputElement>(null);
  const visible = ideas.filter(
    (idea) =>
      (filter === "All ideas" ||
        (filter === "Saved" && saved.includes(idea.id)) ||
        idea.category === filter) &&
      `${idea.title} ${idea.author} ${categoryLabels[idea.category]}`
        .toLowerCase()
        .includes(query.toLowerCase()),
  );
  useEffect(() => {
    if (selected) detailDialog.current?.showModal();
  }, [selected]);
  function toggleSaved(id: number) {
    setSaved((previous) =>
      previous.includes(id)
        ? previous.filter((value) => value !== id)
        : [...previous, id],
    );
  }
  function openAdd() {
    setNewTitle("");
    setFormError("");
    addDialog.current?.showModal();
    newTitleInput.current?.focus();
  }
  function addIdea(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!newTitle.trim()) {
      setFormError("先给灵感起个名字，就能把它留在这里。");
      newTitleInput.current?.focus();
      return;
    }
    setIdeas((previous) => [
      {
        id: Date.now(),
        title: newTitle.trim(),
        category: newCategory,
        author: "你的原野手记",
        art:
          newCategory === "Objects"
            ? "objects"
            : newCategory === "Branding"
              ? "company"
              : "weather",
        description:
          "你最新的一页原野手记。一个值得留存的小灵感，正等待长成美好的模样。",
      },
      ...previous,
    ]);
    setFilter("All ideas");
    setQuery("");
    addDialog.current?.close();
  }
  return (
    <div className="field-app">
      <header className="site-header">
        <a href="/" className="brand" aria-label="灵感原野首页">
          灵感<span className="brand-field">原野</span>
          <span className="brand-dot">®</span>
        </a>
        <nav aria-label="主导航">
          <button
            className="nav-active"
            onClick={() => {
              setFilter("All ideas");
              setQuery("");
            }}
          >
            我的收藏集
          </button>
          <button onClick={() => aboutDialog.current?.showModal()}>
            关于这片原野 <span>↗</span>
          </button>
        </nav>
        <div className="header-actions">
          <button
            className="saved-toggle"
            aria-label={`查看 ${saved.length} 条已收藏的灵感`}
            onClick={() => setFilter("Saved")}
          >
            <Icon name="bookmark" />
            <span>{saved.length}</span>
          </button>
          <button className="add-button" onClick={openAdd}>
            <Icon name="plus" size={16} />
            添加灵感
          </button>
          <span className="profile-avatar" aria-label="个人收藏集">
            你
          </span>
        </div>
      </header>
      <main>
        <section className="intro">
          <div>
            <p className="eyebrow">
              <span />我的私人灵感集
            </p>
            <h1>
              为美好
              <br />
              <i>留一片原野。</i>
              <span className="heading-star" aria-hidden="true">
                ✳
              </span>
            </h1>
          </div>
          <div className="intro-note">
            <p>
              有些事物让人眼前一亮，
              <br />
              留在心里，也值得好好珍藏。
            </p>
            <span>慢慢收集，用心创造。</span>
            <div className="note-line" />
          </div>
        </section>
        <section className="collection" aria-label="灵感收藏集">
          <div className="collection-toolbar">
            <div className="filters" aria-label="筛选灵感">
              {["All ideas", "Branding", "Digital", "Objects", "Saved"].map(
                (name) => (
                  <button
                    key={name}
                    className={filter === name ? "selected" : ""}
                    aria-pressed={filter === name}
                    onClick={() => setFilter(name)}
                  >
                    {filterLabels[name]}
                    <span>
                      {name === "All ideas"
                        ? ideas.length
                        : name === "Saved"
                          ? saved.length
                          : ideas.filter((idea) => idea.category === name)
                              .length}
                    </span>
                  </button>
                ),
              )}
            </div>
            <label className="search">
              <Icon name="search" size={15} />
              <input
                aria-label="搜索灵感"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="找一点灵感……"
              />
            </label>
          </div>
          <div className="idea-grid">
            {visible.map((idea) => (
              <article className="idea-card" key={idea.id}>
                <button
                  className="art-button"
                  aria-label={`查看《${idea.title}》`}
                  onClick={() => setSelected(idea)}
                >
                  <Art kind={idea.art} />
                  <span className="open-idea">
                    <Icon name="arrow" size={18} />
                  </span>
                </button>
                <div className="idea-info">
                  <div>
                    <span className="idea-category">
                      {categoryLabels[idea.category]}
                      <span> / </span>
                      {idea.author}
                    </span>
                    <h2>
                      <button onClick={() => setSelected(idea)}>
                        {idea.title}
                      </button>
                    </h2>
                  </div>
                  <button
                    className={`save-button ${saved.includes(idea.id) ? "is-saved" : ""}`}
                    aria-label={`${saved.includes(idea.id) ? "取消收藏" : "收藏"}《${idea.title}》`}
                    aria-pressed={saved.includes(idea.id)}
                    onClick={() => toggleSaved(idea.id)}
                  >
                    <Icon
                      name="bookmark"
                      size={16}
                      filled={saved.includes(idea.id)}
                    />
                  </button>
                </div>
              </article>
            ))}
          </div>
          {visible.length === 0 && (
            <div className="empty-state">
              <Icon name="search" size={28} />
              <h2>为新灵感留一点空间。</h2>
              <p>
                这里还没有符合条件的灵感。换个筛选条件，或添上你自己的想法吧。
              </p>
              <button
                className="add-button"
                onClick={() => {
                  setFilter("All ideas");
                  setQuery("");
                }}
              >
                查看全部灵感
                <Icon name="arrow" size={16} />
              </button>
            </div>
          )}
        </section>
        <footer className="site-footer">
          <span>好灵感，从留心开始。</span>
          <span>
            怀着好奇，发现美好{" "}
            <span className="footer-star" aria-hidden="true">
              ✳
            </span>{" "}
            灵感原野，2026
          </span>
        </footer>
      </main>
      <dialog
        ref={detailDialog}
        className="detail-dialog"
        onClose={() => setSelected(null)}
        onClick={(event) => {
          if (event.target === event.currentTarget)
            detailDialog.current?.close();
        }}
        aria-labelledby="idea-title"
      >
        {selected && (
          <>
            <div className="detail-art">
              <Art kind={selected.art} />
              <button
                className="close-button"
                aria-label="关闭灵感详情"
                onClick={() => detailDialog.current?.close()}
              >
                <Icon name="close" />
              </button>
            </div>
            <div className="detail-copy">
              <span className="idea-category">
                {categoryLabels[selected.category]} / {selected.author}
              </span>
              <h2 id="idea-title">{selected.title}</h2>
              <p>{selected.description}</p>
              <button
                className="add-button"
                onClick={() => toggleSaved(selected.id)}
              >
                <Icon
                  name={saved.includes(selected.id) ? "check" : "bookmark"}
                  size={16}
                />
                {saved.includes(selected.id)
                  ? "已加入你的收藏集"
                  : "收藏这份灵感"}
              </button>
            </div>
          </>
        )}
      </dialog>
      <dialog
        ref={addDialog}
        className="form-dialog"
        aria-labelledby="new-idea-title"
        onClick={(event) => {
          if (event.target === event.currentTarget) addDialog.current?.close();
        }}
      >
        <form onSubmit={addIdea}>
          <div className="dialog-heading">
            <span className="eyebrow">新的一页原野手记</span>
            <button
              type="button"
              className="close-button"
              aria-label="关闭添加灵感"
              onClick={() => addDialog.current?.close()}
            >
              <Icon name="close" />
            </button>
          </div>
          <h2 id="new-idea-title">
            总有一些美好
            <br />
            <i>值得留下。</i>
          </h2>
          <p>好灵感，常从小小的念头开始。</p>
          <label htmlFor="idea-name">什么让你眼前一亮？</label>
          <input
            ref={newTitleInput}
            id="idea-name"
            value={newTitle}
            maxLength={80}
            onChange={(event) => setNewTitle(event.target.value)}
            placeholder="为这份灵感起个名字"
            aria-invalid={Boolean(formError)}
            aria-describedby="idea-error"
          />
          <p id="idea-error" className="form-error" role="status">
            {formError}
          </p>
          <label htmlFor="idea-category">为灵感选个分类</label>
          <select
            id="idea-category"
            value={newCategory}
            onChange={(event) => setNewCategory(event.target.value as Category)}
          >
            <option value="Digital">数字设计</option>
            <option value="Branding">品牌视觉</option>
            <option value="Objects">器物设计</option>
          </select>
          <button className="add-button" type="submit">
            <Icon name="plus" size={16} />
            收藏这份灵感
          </button>
        </form>
      </dialog>
      <dialog
        ref={aboutDialog}
        className="form-dialog about-dialog"
        aria-labelledby="about-title"
        onClick={(event) => {
          if (event.target === event.currentTarget)
            aboutDialog.current?.close();
        }}
      >
        <div className="dialog-heading">
          <span className="eyebrow">关于这片原野</span>
          <button
            className="close-button"
            aria-label="关闭关于窗口"
            onClick={() => aboutDialog.current?.close()}
          >
            <Icon name="close" />
          </button>
        </div>
        <h2 id="about-title">
          带着好奇看世界。
          <br />
          <i>为灵感留片原野。</i>
        </h2>
        <p>
          灵感原野是界面图鉴的原创示例，收集了一些想象中的器物、品牌视觉与界面设计。每一幅插画都由 CSS 在本地绘制。
        </p>
        <p>
          试着切换分类、收藏心头好、查看作品详情，或添加一页原野手记。这里是一处本地设计试验，你的更改仅在本次预览中保留。
        </p>
        <button
          className="add-button"
          onClick={() => aboutDialog.current?.close()}
        >
          回到美好事物中
          <Icon name="arrow" size={16} />
        </button>
      </dialog>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
