import { mkdir, readdir, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';

function screeningTable() {
  const lines = ['date\tstart\troom\tstatus\treel\tnote'];
  const highlights = new Map([
    [11, ['17:40', 'glass-garden']], [68, ['09:05', 'linen-cloud']],
    [123, ['13:25', 'underpass']], [194, ['10:50', 'paper-orbit']],
    [217, ['19:15', 'salt-window']],
  ]);
  const notes = ['Open captions available', 'Digital restoration', 'First festival screening', 'Archive selection'];
  for (let i = 0; i < 225; i++) {
    const item = highlights.get(i);
    const day = item || i % 3 !== 0 ? '2028-05-18' : '2028-05-19';
    const room = item || i % 3 !== 1 ? 'BLUE' : 'GOLD';
    const status = item || i % 3 !== 2 ? 'confirmed' : 'tentative';
    const start = item?.[0] ?? `${String(8 + i % 14).padStart(2, '0')}:${String(i * 5 % 60).padStart(2, '0')}`;
    const slug = item?.[1] ?? `selection-${String(i).padStart(3, '0')}`;
    lines.push([day, start, room, status, `reels/${slug}.mp4`, notes[i % notes.length]].join('\t'));
  }
  return lines.join('\n') + '\n';
}

const rawCases = [
  {
    id: 'screening-list',
    prompt: '请根据 project/schedule.tsv，给 2028-05-18 的 BLUE 厅做一份正式播放清单。只收录 confirmed 的场次，按开场时间从早到晚排列。把清单存为 project/blue.m3u，每行一个原始片源路径，可有标准 M3U 头。请保留原排片表。',
    files: { 'schedule.tsv': screeningTable() },
  },
  {
    id: 'rgb-export',
    prompt: '请修好 project/main.c 的颜色导出器。每行输入三个十进制整数 R G B，每个通道都应限制在 0 到 255（含边界），每行输出一个大写的 #RRGGBB，低位补零。其他项目也使用 project/include/pixel.h 里的 pixel_channel(int)，请保留这个接口，让调用它也能得到同样的通道值。用 project/sample.txt 试跑，把标准输出保存到 project/colors.txt，保留样例原文。',
    files: {
      'include/pixel.h': '#ifndef PIXEL_H\n#define PIXEL_H\n\nstatic int pixel_channel(int n) {\n    return n < 0 ? 0 : (n > 100 ? 100 : n);\n}\n\n#endif\n',
      'main.c': '#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include "include/pixel.h"\n\nint main(void) {\n    char row[120];\n    while (fgets(row, sizeof row, stdin)) {\n        char *r = row;\n        char *g = strchr(r, \' \');\n        if (!g) return 2;\n        *g++ = 0;\n        char *b = strchr(g, \' \');\n        if (!b) return 2;\n        *b++ = 0;\n        printf("#%X%X%X\\n", pixel_channel(atoi(r)), pixel_channel(atoi(g)), pixel_channel(atoi(b)));\n    }\n    return 0;\n}\n',
      'sample.txt': '2 15 160\n-8 255 300\n',
    },
  },
  {
    id: 'parcel-lines',
    prompt: 'project/main.c 原来用来清点包裹标签，现在编译不过了。请修复它，并确认每个非空标签行计一件，只有空格、制表符或回车的行不计，最后一行即使没有换行也要计入。保持现有的输出格式「parcels=件数」，用 project/incoming.txt 实际跑一次，把输出保存为 project/count.txt；来货清单原样保留。',
    files: {
      'main.c': '#include <stdio.h>\n\nstatic int label_byte(int ch) {\n    return ch != \' \' && ch != \'\\t\' && ch != \'\\r\';\n}\n\nint main(void) {\n    int ch, count = 0, pending = 0;\n    while ((ch = getchar()) != EOF) {\n        if (ch == \'\\n\') {\n            count += pending;\n            pending = 0;\n        } else if (label_byte()) {\n            pending = 1;\n        }\n    }\n    printf("parcels=%d\\n", count);\n    return 0;\n}\n',
      'incoming.txt': 'BOX-41\n \t\nCRATE-07\nPOUCH-16',
    },
  },
  {
    id: 'event-brief',
    prompt: '请合并 project/agenda.md 和 project/updates.md，做一份志愿者能直接用的最终日程 project/brief.md。仅列保留的活动，按最终开始时间排序，每场单独一行写出原活动名、24 小时制时间和最终场地代码。两份来源照原样保留。',
    files: {
      'agenda.md': '# 周末材料工坊 · 初排\n\n| 活动 | 时间 | 场地 |\n| --- | --- | --- |\n| 纸桥搭建 | 09:30 | H1 |\n| 树叶拓印 | 10:45 | H2 |\n| 声音地图 | 14:10 | H3 |\n| 纸偶排演 | 16:00 | H4 |\n',
      'updates.md': '# 截止开场前的确认单\n\n- 第一批调整：纸桥搭建延至 11:20，场地仍为 H1。树叶拓印因材料缺货取消。\n- 第二批调整：声音地图提前到 09:50，移至 K7。纸桥搭建又确认改用 K2，时间沿用上一通知。\n- 纸偶排演按初排，也没有待定项目需要加入。\n',
    },
  },
  {
    id: 'shift-span',
    prompt: '请为 project 写一个以后还能使用的标准 C 小工具，入口为 project/main.c。每行输入一对 24 小时时间 HH:MM HH:MM（开始、结束），每行输出相差的整数分钟。结束早于开始表示跨过午夜，两个时刻相同计零。请用 project/shifts.txt 试跑，把结果保存到 project/minutes.txt，每行一个数字，保留原始班表。',
    files: { 'shifts.txt': '08:15 09:00\n23:40 00:10\n12:30 12:30\n' },
  },
  {
    id: 'active-profile',
    prompt: '请按 project/release.json 找到阅读器（reader）目前实际启用的配置，把 network.retry_delay_seconds 调成 4。现行配置里的其他设置保持原值，索引、预览版、归档版和另外一款产品的配置都原样保留。',
    files: {
      'release.json': '{\n  "reader": {"active": "versions/fir/settings.json", "preview": "versions/ash/settings.json", "archive": "archive/fir/settings.json"},\n  "kiosk": {"active": "kiosk/settings.json"}\n}\n',
      'versions/fir/settings.json': '{\n  "network": {"retry_delay_seconds": 2, "attempts": 3},\n  "display": {"theme": "paper", "retry_delay_seconds": 12}\n}\n',
      'versions/ash/settings.json': '{"network":{"retry_delay_seconds":2,"attempts":4},"display":{"theme":"night"}}\n',
      'archive/fir/settings.json': '{"network":{"retry_delay_seconds":2,"attempts":3},"display":{"theme":"paper"}}\n',
      'kiosk/settings.json': '{"network":{"retry_delay_seconds":2,"attempts":6},"display":{"theme":"amber"}}\n',
    },
  },
];

export const cases = rawCases.map(({ id, prompt, files }) => ({
  id, prompt, files: Object.fromEntries(Object.entries(files).map(([p, text]) => ['project/' + p, text])),
}));

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [mode, id, directory] = process.argv.slice(2);
  if (mode === 'pack') {
    process.stdout.write(JSON.stringify(cases, null, 2) + '\n');
  } else {
    const task = cases.find(t => t.id === id);
    if (!task || !['prepare', 'prompt'].includes(mode) || (mode === 'prepare' && !directory)) {
      throw Error('Use: cases.mjs pack | prompt CASE | prepare CASE EMPTY_DIRECTORY');
    }
    if (mode === 'prepare') {
      await mkdir(directory, { recursive: true });
      if ((await readdir(directory)).length) throw Error('Expected an empty workspace root');
      for (const [name, text] of Object.entries(task.files)) {
        const path = resolve(directory, name);
        await mkdir(dirname(path), { recursive: true });
        await writeFile(path, text, { flag: 'wx' });
      }
    } else {
      process.stdout.write(task.prompt);
    }
  }
}
