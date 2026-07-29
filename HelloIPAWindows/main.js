const { app, BrowserWindow, ipcMain, clipboard, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const http = require('http');
const os = require('os');
const crypto = require('crypto');

let windowRef;
let shareServer;
let sharePort;
let notes = [];

const storePath = () => path.join(app.getPath('userData'), 'notes.json');
function loadNotes() {
  try { notes = JSON.parse(fs.readFileSync(storePath(), 'utf8')); } catch { notes = []; }
  if (!Array.isArray(notes) || !notes.length) notes = [{ id: crypto.randomUUID(), text: '欢迎使用 HelloIPA Windows 版\n', modifiedAt: new Date().toISOString() }];
}
function saveNotes() { fs.mkdirSync(path.dirname(storePath()), { recursive: true }); fs.writeFileSync(storePath(), JSON.stringify(notes, null, 2)); }
function localAddress() {
  for (const list of Object.values(os.networkInterfaces())) for (const item of list || [])
    if (item.family === 'IPv4' && !item.internal && item.address.startsWith('192.168.')) return item.address;
  for (const list of Object.values(os.networkInterfaces())) for (const item of list || [])
    if (item.family === 'IPv4' && !item.internal) return item.address;
  return '127.0.0.1';
}
function htmlEscape(value) { return value.replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c])); }
function sharePage() {
  const text = notes.find(n => n.id === shareServer.noteId)?.text || '';
  return `<!doctype html><meta charset="utf-8"><title>HelloIPA 共享</title><style>body{font:16px system-ui;background:#f8f3bc;padding:24px;max-width:760px;margin:auto}textarea{width:100%;min-height:260px;font:17px system-ui;padding:12px}button{margin-top:12px;padding:10px 18px}</style><h2>HelloIPA 共享文本</h2><textarea id=t>${htmlEscape(text)}</textarea><br><button onclick="fetch('/sync',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({text:t.value})}).then(()=>alert('已同步到电脑'))">同步到电脑</button><script>const t=document.querySelector('#t');</script>`;
}
function startServer(noteId) {
  if (shareServer) shareServer.close();
  shareServer = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/') { res.writeHead(200, { 'content-type':'text/html; charset=utf-8' }); return res.end(sharePage()); }
    if (req.method === 'POST' && req.url === '/sync') { let body=''; req.on('data', c => body += c); req.on('end', () => { try { const value=JSON.parse(body).text ?? ''; const note=notes.find(n=>n.id===shareServer.noteId); if(note){note.text=value;note.modifiedAt=new Date().toISOString();saveNotes();windowRef?.webContents.send('notes-updated',notes);} res.writeHead(204); } catch { res.writeHead(400); } res.end(); }); return; }
    res.writeHead(404); res.end();
  });
  shareServer.noteId = noteId;
  return new Promise(resolve => shareServer.listen(0, '0.0.0.0', () => {
    sharePort = shareServer.address().port;
    resolve(`http://${localAddress()}:${sharePort}`);
  }));
}
function stopServer() { if (shareServer) shareServer.close(); shareServer = undefined; sharePort = undefined; }

function createWindow() {
  windowRef = new BrowserWindow({ width: 460, height: 860, minWidth: 360, minHeight: 600, backgroundColor: '#000', webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false } });
  windowRef.loadFile(path.join(__dirname, 'renderer.html'));
  windowRef.on('closed', () => { stopServer(); windowRef = undefined; });
}
app.whenReady().then(() => {
  loadNotes();
  ipcMain.handle('notes:get', () => notes);
  ipcMain.handle('notes:save', (_, value) => { notes = value; saveNotes(); return notes; });
  ipcMain.handle('share:start', (_, id) => startServer(id));
  ipcMain.handle('share:stop', () => { stopServer(); });
  ipcMain.handle('clipboard:write', (_, value) => clipboard.writeText(value));
  ipcMain.handle('open:url', (_, value) => shell.openExternal(value));
  createWindow();
});
app.on('window-all-closed', () => { stopServer(); if (process.platform !== 'darwin') app.quit(); });
