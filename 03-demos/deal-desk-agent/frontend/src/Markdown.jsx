/**
 * Lightweight markdown renderer — no external deps.
 * Handles bold, headers, tables, lists, and horizontal rules.
 */

function parseLine(line) {
  return line
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/\*(.+?)\*/g, '<em>$1</em>')
    .replace(/`(.+?)`/g, '<code style="background:#f3f4f6;padding:1px 5px;border-radius:3px;font-size:12px">$1</code>');
}

function isTableRow(line) {
  return line.trim().startsWith('|') && line.trim().endsWith('|');
}

function isSeparator(line) {
  return /^\|[\s\-:|]+\|$/.test(line.trim());
}

function parseTable(lines) {
  const rows = lines
    .filter(l => !isSeparator(l))
    .map(l => l.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map(c => c.trim()));

  if (rows.length === 0) return '';
  const header = rows[0];
  const body = rows.slice(1);

  return `<table style="width:100%;border-collapse:collapse;margin:8px 0;font-size:13px">
    <thead><tr>${header.map(h => `<th style="text-align:left;padding:6px 10px;border-bottom:2px solid #e5e7eb;font-weight:600;color:#374151">${parseLine(h)}</th>`).join('')}</tr></thead>
    <tbody>${body.map((row, i) => `<tr style="background:${i % 2 === 0 ? '#ffffff' : '#f9fafb'}">${row.map(c => `<td style="padding:5px 10px;border-bottom:1px solid #f3f4f6;color:#4b5563">${parseLine(c)}</td>`).join('')}</tr>`).join('')}</tbody>
  </table>`;
}

export function renderMarkdown(text) {
  if (!text) return '';
  const lines = text.split('\n');
  let html = '';
  let i = 0;
  let inTable = false;
  let tableLines = [];

  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    // Table
    if (isTableRow(trimmed)) {
      if (!inTable) { inTable = true; tableLines = []; }
      tableLines.push(trimmed);
      i++;
      continue;
    } else if (inTable) {
      html += parseTable(tableLines);
      inTable = false;
      tableLines = [];
    }

    // Horizontal rule
    if (/^-{3,}$/.test(trimmed) || /^\*{3,}$/.test(trimmed)) {
      html += '<hr style="border:none;border-top:1px solid #e5e7eb;margin:10px 0" />';
      i++;
      continue;
    }

    // Headers
    if (trimmed.startsWith('#### ')) {
      html += `<div style="font-size:13px;font-weight:700;color:#374151;margin:10px 0 4px">${parseLine(trimmed.slice(5))}</div>`;
      i++; continue;
    }
    if (trimmed.startsWith('### ')) {
      html += `<div style="font-size:14px;font-weight:700;color:#111827;margin:12px 0 4px">${parseLine(trimmed.slice(4))}</div>`;
      i++; continue;
    }
    if (trimmed.startsWith('## ')) {
      html += `<div style="font-size:15px;font-weight:700;color:#111827;margin:14px 0 6px">${parseLine(trimmed.slice(3))}</div>`;
      i++; continue;
    }
    if (trimmed.startsWith('# ')) {
      html += `<div style="font-size:16px;font-weight:700;color:#111827;margin:16px 0 8px">${parseLine(trimmed.slice(2))}</div>`;
      i++; continue;
    }

    // Blockquote
    if (trimmed.startsWith('> ')) {
      html += `<div style="border-left:3px solid #d1d5db;padding:4px 12px;margin:6px 0;color:#6b7280;font-style:italic">${parseLine(trimmed.slice(2))}</div>`;
      i++; continue;
    }

    // List item
    if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
      html += `<div style="display:flex;gap:6px;padding:2px 0"><span style="color:#9ca3af">•</span><span>${parseLine(trimmed.slice(2))}</span></div>`;
      i++; continue;
    }

    // Numbered list
    if (/^\d+\.\s/.test(trimmed)) {
      const num = trimmed.match(/^(\d+)\.\s/)[1];
      const content = trimmed.replace(/^\d+\.\s/, '');
      html += `<div style="display:flex;gap:6px;padding:2px 0"><span style="color:#9ca3af;min-width:16px">${num}.</span><span>${parseLine(content)}</span></div>`;
      i++; continue;
    }

    // Empty line
    if (trimmed === '') {
      html += '<div style="height:6px"></div>';
      i++; continue;
    }

    // Regular paragraph
    html += `<div style="padding:1px 0">${parseLine(trimmed)}</div>`;
    i++;
  }

  // Flush remaining table
  if (inTable) html += parseTable(tableLines);

  return html;
}

export default function Markdown({ text }) {
  return <div dangerouslySetInnerHTML={{ __html: renderMarkdown(text) }} />;
}
