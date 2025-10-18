const { main } = imports.ui;
const { QuickSettingsItem } = imports.ui.quickSettings;
const St = imports.gi.St; const GLib = imports.gi.GLib;
let btn;
function enable(){
  const icon = new St.Icon({ icon_name:'info-symbolic', style_class:'system-status-icon' });
  btn = new QuickSettingsItem({ title:'About Solvionyx', icon });
  btn.connect('clicked', ()=> GLib.spawn_command_line_async('python3 /usr/share/solvionyx/about-solvionyx.py'));
  main.panel.statusArea.quickSettings._addItems([btn], -1);
}
function disable(){ if(btn) btn.destroy(); }
