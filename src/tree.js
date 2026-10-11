import fs from 'node:fs';
import path from 'node:path';

export function assembleSummaryTree(scopesDir) {
  if (!fs.existsSync(scopesDir)) return '';
  const dirs = fs
    .readdirSync(scopesDir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);

  const nodes = {};
  for (const dir of dirs) {
    const metaPath = path.join(scopesDir, dir, 'meta.json');
    const summaryPath = path.join(scopesDir, dir, 'summary.md');
    let meta = { slug: dir, parentSlug: null };
    try {
      meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
    } catch {
      // fallback
    }
    const content = fs.existsSync(summaryPath)
      ? fs.readFileSync(summaryPath, 'utf8').trim()
      : '';
    nodes[meta.slug] = { ...meta, content, children: [] };
  }

  const roots = [];
  for (const node of Object.values(nodes)) {
    if (node.parentSlug && nodes[node.parentSlug]) {
      nodes[node.parentSlug].children.push(node);
    } else {
      roots.push(node);
    }
  }

  function render(node) {
    if (!node.content) return '';
    if (!node.children.length) return node.content;
    const childMd = node.children.map(render).filter(Boolean).join('\n\n');
    const closeIdx = node.content.lastIndexOf('</details>');
    return closeIdx !== -1
      ? `${node.content.slice(0, closeIdx)}\n\n${childMd}\n${node.content.slice(closeIdx)}`
      : `${node.content}\n\n${childMd}`;
  }

  return roots.map(render).filter(Boolean).join('\n\n');
}

if (process.argv[1]?.endsWith('tree.js') && process.argv[2]) {
  process.stdout.write(assembleSummaryTree(process.argv[2]));
}
