<script setup lang="ts">
import { computed, nextTick, ref } from "vue";
import Icon from "./Icon.vue";

type Task = {
  id: number;
  title: string;
  category: "工作" | "生活";
  time: string;
  done: boolean;
};
const requestedView = new URLSearchParams(window.location.search).get("view");
const view =
  requestedView === "mobile" || requestedView === "desktop"
    ? requestedView
    : "web";
const selectedDay = ref(6);
const activeList = ref("今天");
const filter = ref("全部");
const focusActive = ref(false);
const taskDialog = ref<HTMLDialogElement | null>(null);
const taskInput = ref<HTMLInputElement | null>(null);
const taskTitle = ref("");
const taskCategory = ref<"工作" | "生活">("工作");
const taskError = ref("");
const tasks = ref<Task[]>([
  {
    id: 1,
    title: "把新想法整理成一个小小的提案",
    category: "工作",
    time: "09:30",
    done: false,
  },
  {
    id: 2,
    title: "读完《设计中的设计》这一章",
    category: "生活",
    time: "11:00",
    done: true,
  },
  {
    id: 3,
    title: "为 Still 画出下一张草图",
    category: "工作",
    time: "14:00",
    done: false,
  },
  {
    id: 4,
    title: "散步，去发现一棵好看的树",
    category: "生活",
    time: "17:30",
    done: false,
  },
]);
const shownTasks = computed(() =>
  tasks.value.filter((task) => {
    const category =
      activeList.value === "工作项目"
        ? "工作"
        : activeList.value === "生活清单"
          ? "生活"
          : filter.value;
    return category === "全部" || task.category === category;
  }),
);
const completeCount = computed(
  () => tasks.value.filter((task) => task.done).length,
);
const heading = computed(() =>
  activeList.value === "今天"
    ? "把今天，过得轻一点。"
    : activeList.value === "本周计划"
      ? "留一点空间，给新的可能。"
      : activeList.value === "工作项目"
        ? "专注于，真正重要的事。"
        : "平凡的日子，也值得认真。",
);
const week = [
  { day: "一", date: 2 },
  { day: "二", date: 3 },
  { day: "三", date: 4 },
  { day: "四", date: 5 },
  { day: "五", date: 6 },
  { day: "六", date: 7 },
  { day: "日", date: 8 },
];

async function openTaskDialog() {
  taskTitle.value = "";
  taskError.value = "";
  taskDialog.value?.showModal();
  await nextTick();
  taskInput.value?.focus();
}
function addTask() {
  const title = taskTitle.value.trim();
  if (!title) {
    taskError.value = "给这件小事起个名字吧。";
    taskInput.value?.focus();
    return;
  }
  tasks.value.push({
    id: Date.now(),
    title,
    category: taskCategory.value,
    time: "待安排",
    done: false,
  });
  filter.value = "全部";
  activeList.value = "今天";
  taskDialog.value?.close();
}
function selectList(name: string) {
  activeList.value = name;
  filter.value = "全部";
}
</script>

<template>
  <div class="still-app" :class="view">
    <aside v-if="view === 'desktop'" class="desktop-sidebar">
      <a class="brand" href="?view=desktop" aria-label="Still 首页"
        ><span class="brand-mark"><Icon name="leaf" :size="21" /></span
        >still<span class="brand-dot">.</span></a
      >
      <div class="workspace-label">个人工作空间 <span>⌄</span></div>
      <nav aria-label="工作空间导航">
        <button
          v-for="item in [
            { name: '今天', icon: 'sun' },
            { name: '本周计划', icon: 'calendar' },
            { name: '工作项目', icon: 'folder' },
            { name: '生活清单', icon: 'leaf' },
          ]"
          :key="item.name"
          :class="{ active: activeList === item.name }"
          @click="selectList(item.name)"
        >
          <Icon :name="item.icon" /><span>{{ item.name }}</span
          ><span v-if="item.name === '今天'" class="nav-count">{{
            tasks.length
          }}</span>
        </button>
      </nav>
      <div class="sidebar-note">
        <span class="small-label">A LITTLE REMINDER</span>
        <p>慢慢来，<br />也会走得很远。</p>
        <div class="note-sprout" aria-hidden="true">
          <span></span><i></i><b></b>
        </div>
      </div>
      <button class="sidebar-profile" @click="selectList('生活清单')">
        <span class="avatar">Y</span
        ><span>你的日常<small>留白练习者</small></span
        ><Icon name="more" :size="18" />
      </button>
    </aside>

    <main class="main-area">
      <div v-if="view === 'mobile'" class="mobile-status" aria-hidden="true">
        <span>9:41</span
        ><span class="status-bars"><i></i><i></i><i></i><i></i><b></b></span>
      </div>
      <header v-if="view !== 'mobile'" class="topbar">
        <a
          v-if="view === 'web'"
          class="brand"
          href="?view=web"
          aria-label="Still 首页"
          ><span class="brand-mark"><Icon name="leaf" :size="21" /></span
          >still<span class="brand-dot">.</span></a
        >
        <span v-else class="breadcrumb"
          >工作空间 <span>/</span> {{ activeList }}</span
        >
        <nav v-if="view === 'web'" class="web-nav" aria-label="主导航">
          <button
            v-for="item in ['今天', '本周计划', '生活清单']"
            :key="item"
            :class="{ active: activeList === item }"
            @click="selectList(item)"
          >
            {{ item }}
          </button>
        </nav>
        <div class="topbar-right">
          <span class="weather"><Icon name="sun" :size="17" />22°，晴</span
          ><span class="avatar">Y</span>
        </div>
      </header>
      <section class="app-content">
        <header class="greeting">
          <div>
            <div class="eyebrow">
              <span v-if="view === 'mobile'">HELLO, FRIDAY</span
              ><span v-else
                >2026 年 11 月 {{ selectedDay }} 日 · 星期{{
                  week.find((day) => day.date === selectedDay)?.day
                }}</span
              ><span class="greeting-rule"></span>
            </div>
            <h1>{{ heading }}</h1>
            <p>不必填满每个时刻，做好眼前的一件事就很好。</p>
          </div>
          <button
            v-if="view === 'mobile'"
            class="avatar mobile-avatar"
            aria-label="打开生活清单"
            @click="selectList('生活清单')"
          >
            Y
          </button>
          <button v-else class="new-task" @click="openTaskDialog">
            <Icon name="plus" :size="18" />记一件小事
          </button>
        </header>
        <div
          v-if="view === 'mobile' || activeList === '本周计划'"
          class="date-strip"
          aria-label="选择日期"
        >
          <button
            v-for="day in week"
            :key="day.date"
            :class="{ selected: selectedDay === day.date }"
            :aria-pressed="selectedDay === day.date"
            @click="selectedDay = day.date"
          >
            <span>{{ day.day }}</span
            ><strong>{{ day.date }}</strong
            ><i v-if="day.date === 6"></i>
          </button>
        </div>

        <div class="content-grid">
          <section class="task-panel">
            <div class="panel-heading">
              <h2>
                {{
                  activeList === "本周计划"
                    ? `11 月 ${selectedDay} 日的小事`
                    : activeList === "今天"
                      ? "今日小事"
                      : activeList
                }}<span>{{ completeCount }}/{{ tasks.length }}</span>
              </h2>
              <button
                v-if="view === 'mobile'"
                class="icon-button"
                aria-label="新建任务"
                @click="openTaskDialog"
              >
                <Icon name="plus" /></button
              ><span v-else class="panel-note">一点一点，慢慢完成</span>
            </div>
            <div class="task-filters" aria-label="任务分类">
              <button
                v-for="name in ['全部', '工作', '生活']"
                :key="name"
                :class="{ selected: filter === name }"
                :aria-pressed="filter === name"
                @click="
                  filter = name;
                  activeList = '今天';
                "
              >
                {{ name }}
              </button>
            </div>
            <div class="task-list">
              <article
                v-for="task in shownTasks"
                :key="task.id"
                class="task-row"
                :class="{ completed: task.done }"
              >
                <button
                  class="task-check"
                  :aria-label="`${task.done ? '取消完成' : '完成'}：${task.title}`"
                  :aria-pressed="task.done"
                  @click="task.done = !task.done"
                >
                  <Icon v-if="task.done" name="check" :size="13" />
                </button>
                <div class="task-copy">
                  <h3>{{ task.title }}</h3>
                  <span
                    ><i :class="task.category === '生活' ? 'life-dot' : ''"></i
                    >{{ task.category }}<span class="meta-divider">·</span
                    >{{ task.time }}</span
                  >
                </div>
                <span v-if="view !== 'mobile'" class="task-priority">{{
                  task.category === "工作" ? "专注" : "从容"
                }}</span>
              </article>
              <p v-if="shownTasks.length === 0" class="empty-tasks">
                这里还很安静，记下第一件小事吧。
              </p>
            </div>
            <button class="add-inline" @click="openTaskDialog">
              <Icon name="plus" :size="17" />留个位置，给接下来的小事
            </button>
          </section>

          <aside class="right-column">
            <section class="focus-card" :class="{ focusing: focusActive }">
              <div class="focus-card-copy">
                <span class="small-label">{{
                  focusActive ? "JUST THIS MOMENT" : "A MOMENT FOR YOURSELF"
                }}</span>
                <h2>
                  {{
                    focusActive
                      ? "世界稍等，\n我在专注。"
                      : "留 25 分钟，\n只做一件事。"
                  }}
                </h2>
                <button @click="focusActive = !focusActive">
                  <Icon
                    :name="focusActive ? 'check' : 'headphones'"
                    :size="16"
                  />{{ focusActive ? "结束这次专注" : "开始一段专注"
                  }}<Icon name="arrow" :size="15" />
                </button>
              </div>
              <div class="focus-orbit" aria-hidden="true">
                <div></div>
                <div></div>
                <div></div>
                <span><Icon name="leaf" :size="42" /></span>
              </div>
            </section>
            <section class="weekly-card">
              <div class="weekly-top">
                <div>
                  <span class="small-label">YOUR LITTLE PROGRESS</span>
                  <h2>一周的，小小积累</h2>
                </div>
                <Icon name="chart" :size="19" />
              </div>
              <div class="weekly-number">
                {{ 12 + completeCount }}<span>件值得记住的小事</span>
              </div>
              <div class="week-bars" aria-label="本周每日完成小事数量">
                <div
                  v-for="(height, index) in [38, 65, 49, 85, 58, 28, 19]"
                  :key="index"
                >
                  <i
                    :class="{ today: index === 4 }"
                    :style="{ height: `${height}%` }"
                  ></i
                  ><span>{{
                    ["一", "二", "三", "四", "五", "六", "日"][index]
                  }}</span>
                </div>
              </div>
            </section>
          </aside>
        </div>
        <section v-if="view !== 'mobile'" class="thought-card">
          <span class="thought-icon"><Icon name="note" :size="23" /></span>
          <div>
            <span class="small-label">TODAY'S THOUGHT</span>
            <p>“生活不在于拥有多少，而在于感受到多少。”</p>
          </div>
          <span class="thought-number">NO. 006</span>
        </section>
        <footer class="content-footer">
          <span class="footer-leaf"
            ><Icon name="leaf" :size="14" />一点留白，让日常呼吸。</span
          ><span v-if="view !== 'mobile'">MADE FOR A SLOWER EVERYDAY</span>
        </footer>
      </section>
      <nav
        v-if="view === 'mobile'"
        class="mobile-tabbar"
        aria-label="移动端导航"
      >
        <button
          v-for="item in [
            { name: '今天', icon: 'home', label: '日常' },
            { name: '本周计划', icon: 'calendar', label: '计划' },
            { name: '生活清单', icon: 'leaf', label: '生活' },
          ]"
          :key="item.name"
          :class="{ active: activeList === item.name }"
          @click="selectList(item.name)"
        >
          <Icon :name="item.icon" :size="21" /><span>{{ item.label }}</span>
        </button>
      </nav>
    </main>
    <dialog
      ref="taskDialog"
      class="task-dialog"
      aria-labelledby="task-dialog-title"
      @click="
        (event) => {
          if (event.target === taskDialog) taskDialog?.close();
        }
      "
    >
      <form @submit.prevent="addTask">
        <div class="dialog-top">
          <span class="small-label">MAKE A LITTLE ROOM</span
          ><button
            type="button"
            class="icon-button"
            aria-label="关闭新建任务"
            @click="taskDialog?.close()"
          >
            <Icon name="close" />
          </button>
        </div>
        <h2 id="task-dialog-title">记下一件小事。</h2>
        <p>大大小小，都值得被认真对待。</p>
        <label for="task-title">想做些什么？</label
        ><input
          id="task-title"
          ref="taskInput"
          v-model="taskTitle"
          maxlength="80"
          placeholder="比如，给老朋友打个电话"
          :aria-invalid="Boolean(taskError)"
          aria-describedby="task-error"
        />
        <p id="task-error" class="task-error" role="status">{{ taskError }}</p>
        <label for="task-category">放进哪个清单</label
        ><select id="task-category" v-model="taskCategory">
          <option>工作</option>
          <option>生活</option></select
        ><button class="new-task" type="submit">
          <Icon name="plus" :size="18" />记好了
        </button>
      </form>
    </dialog>
  </div>
</template>
