const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('helloIPA', {
  getNotes: () => ipcRenderer.invoke('notes:get'),
  saveNotes: notes => ipcRenderer.invoke('notes:save', notes),
  startShare: id => ipcRenderer.invoke('share:start', id),
  stopShare: () => ipcRenderer.invoke('share:stop'),
  copy: value => ipcRenderer.invoke('clipboard:write', value),
  openURL: value => ipcRenderer.invoke('open:url', value),
  onNotesUpdated: callback => ipcRenderer.on('notes-updated', (_, value) => callback(value))
});
