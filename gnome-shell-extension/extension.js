// SUPERFAST GNOME Shell extension — a small panel menu to pick the model
// profile and toggle the orchestrator by calling the superfast-switch CLI.
//
// It deliberately keeps no state: every refresh reads the CLI output, so the
// menu always reflects what the machine is really doing, including changes
// made over SSH or from the terminal tool.

import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const PROFILES = ['dense', 'flash', 'gemma', 'deepseek'];

function resolveSwitch() {
    const home = GLib.get_home_dir();
    const candidate = `${home}/.local/bin/superfast-switch`;
    return GLib.file_test(candidate, GLib.FileTest.EXISTS) ? candidate : 'superfast-switch';
}

function runCli(args, onDone) {
    try {
        const proc = Gio.Subprocess.new(
            [resolveSwitch(), ...args],
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        proc.communicate_utf8_async(null, null, (p, res) => {
            let out = '';
            try {
                const [, stdout] = p.communicate_utf8_finish(res);
                out = stdout ?? '';
            } catch (e) {
                out = '';
            }
            if (onDone)
                onDone(out);
        });
    } catch (e) {
        if (onDone)
            onDone('');
    }
}

const SuperfastMenu = GObject.registerClass(
class SuperfastMenu extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'SUPERFAST');
        this.add_child(new St.Icon({
            icon_name: 'utilities-system-monitor-symbolic',
            style_class: 'system-status-icon',
        }));

        this._statusItem = new PopupMenu.PopupMenuItem('checking…', {reactive: false});
        this.menu.addMenuItem(this._statusItem);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._modelSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._modelSection);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._orchItem = new PopupMenu.PopupMenuItem('Orchestrator: …');
        this._orchItem.connect('activate', () => {
            const on = this._orchestratorActive;
            runCli(['orchestrator', on ? 'off' : 'on'], () => this.refresh());
        });
        this.menu.addMenuItem(this._orchItem);

        this.menu.addMenuItem(new PopupMenu.PopupMenuItem('Refresh')).connect('activate',
            () => this.refresh());

        this._termItem = new PopupMenu.PopupMenuItem('Open terminal menu');
        this._termItem.connect('activate', () => {
            const tui = `${GLib.get_home_dir()}/.local/bin/superfast-tui`;
            const cmd = GLib.file_test(tui, GLib.FileTest.EXISTS) ? tui : 'superfast-tui';
            GLib.spawn_command_line_async(`gnome-terminal -- ${cmd}`);
        });
        this.menu.addMenuItem(this._termItem);

        this.refresh();
    }

    refresh() {
        runCli(['status'], out => {
            const active = (out.match(/^\s*(\w+)\s+\S+\s+active/m) || [])[1] ?? null;
            this._orchestratorActive = /orchestrator\.service\s+active/.test(out);
            const serving = (out.match(/serving now:\s*(.+)$/m) || [])[1] ?? 'nothing';
            this._statusItem.label.text = `Serving: ${serving}`;
            this._orchItem.label.text =
                `Orchestrator: ${this._orchestratorActive ? 'on' : 'off'}`;

            this._modelSection.removeAll();
            for (const p of PROFILES) {
                const label = `${p === active ? '● ' : '○ '}${p}`;
                const item = new PopupMenu.PopupMenuItem(label);
                item.connect('activate', () => runCli(['use', p], () => {
                    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1500, () => {
                        this.refresh();
                        return GLib.SOURCE_REMOVE;
                    });
                }));
                this._modelSection.addMenuItem(item);
            }
        });
    }
});

export default class SuperfastExtension extends Extension {
    enable() {
        this._menu = new SuperfastMenu();
        Main.panel.addToStatusArea(this.uuid, this._menu);
    }

    disable() {
        this._menu?.destroy();
        this._menu = null;
    }
}
