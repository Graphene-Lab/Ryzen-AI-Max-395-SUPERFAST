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

// How to start a terminal that runs a command. The first two use the
// `program -- command args` form, the last two the older `-e` form. Ptyxis is
// the terminal Fedora ships now; gnome-terminal is NOT installed on Fedora 44,
// which is why this list is resolved at runtime instead of being hardcoded.
const TERMINALS = [
    ['ptyxis', '--'],
    ['gnome-terminal', '--'],
    ['kgx', '--'],
    ['xterm', '-e'],
    ['konsole', '-e'],
];

// The argv for the switch CLI: the installed absolute path when there is one,
// otherwise /usr/bin/env so that the PATH is searched explicitly.
function switchArgv(args) {
    const installed = `${GLib.get_home_dir()}/.local/bin/superfast-switch`;
    if (GLib.file_test(installed, GLib.FileTest.EXISTS))
        return [installed, ...args];
    return ['/usr/bin/env', 'superfast-switch', ...args];
}

// The argv that opens the TUI in a terminal, or null when no terminal exists.
function tuiTerminalArgv() {
    const installed = `${GLib.get_home_dir()}/.local/bin/superfast-tui`;
    const tui = GLib.file_test(installed, GLib.FileTest.EXISTS) ? installed : 'superfast-tui';
    for (const [program, style] of TERMINALS) {
        const path = GLib.find_program_in_path(program);
        if (path)
            return [path, style, tui];
    }
    return null;
}

function runCli(args, onDone) {
    try {
        const proc = Gio.Subprocess.new(
            switchArgv(args),
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
        logError(e, 'SUPERFAST: could not run superfast-switch');
        if (onDone)
            onDone('');
    }
}

const SuperfastMenu = GObject.registerClass(
class SuperfastMenu extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'SUPERFAST');
        this._pollLeft = 0;
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
            runCli(['orchestrator', on ? 'off' : 'on'], () => this.poll());
        });
        this.menu.addMenuItem(this._orchItem);

        // Note: since GNOME 45, `menu.addMenuItem()` returns nothing, so the
        // item has to be created, connected and then added — chaining
        // `.connect()` on the return value throws and the whole extension goes
        // to State: ERROR (found on the reference machine's live session).
        const refreshItem = new PopupMenu.PopupMenuItem('Refresh');
        refreshItem.connect('activate', () => this.refresh());
        this.menu.addMenuItem(refreshItem);

        this._termItem = new PopupMenu.PopupMenuItem('Open terminal menu');
        this._termItem.connect('activate', () => {
            const argv = tuiTerminalArgv();
            if (!argv) {
                this._statusItem.label.text = 'No terminal emulator found';
                return;
            }
            try {
                Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
            } catch (e) {
                logError(e, 'SUPERFAST: could not open a terminal');
                this._statusItem.label.text = 'Could not open a terminal';
            }
        });
        this.menu.addMenuItem(this._termItem);

        this.refresh();
    }

    // A profile takes from a few seconds to a minute and a half to load, so the
    // menu refreshes itself for a while instead of once.
    poll(rounds = 14) {
        this.stopPolling();
        this._pollLeft = rounds;
        this._pollId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 5000, () => {
            this.refresh();
            this._pollLeft -= 1;
            if (this._pollLeft > 0)
                return GLib.SOURCE_CONTINUE;
            this._pollId = null;
            return GLib.SOURCE_REMOVE;
        });
    }

    // Called from disable(): a timer left running would call refresh() on a
    // destroyed menu, which the shell reports as a JS error.
    stopPolling() {
        if (this._pollId) {
            GLib.source_remove(this._pollId);
            this._pollId = null;
        }
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
                item.connect('activate', () => runCli(['use', p], () => this.poll()));
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
        this._menu?.stopPolling();
        this._menu?.destroy();
        this._menu = null;
    }
}
