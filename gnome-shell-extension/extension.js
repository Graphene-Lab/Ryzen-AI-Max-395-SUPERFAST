// SUPERFAST GNOME Shell extension — a small panel menu to pick the model
// profile, toggle the orchestrator and manage the LAN API key, by calling the
// superfast-switch CLI.
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
        // _busy is true while a model restart is in flight (a profile switch
        // or a vision toggle). While it is, the action items are insensitive
        // so a second change cannot start on top of one already running.
        this._busy = false;
        // _syncing guards the vision switch so a programmatic state update in
        // refresh() does not fire its 'toggled' handler (which would start a
        // toggle we did not ask for).
        this._syncing = false;
        this._visionSupported = false;
        this._visionEnabled = false;
        this._modelItems = [];
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

        // Vision toggle for the active profile. It is sensitive only when the
        // running model can carry a vision component (flash, gemma) and no
        // restart is in flight; on the text-only profiles (dense, deepseek)
        // it stays off and greyed out. Toggling restarts the profile and drops
        // its prompt cache, so it is meant to be used between conversations.
        this._visionSwitch = new PopupMenu.PopupSwitchMenuItem('Vision', false);
        this._visionSwitch.connect('toggled', (item) => {
            if (this._syncing)
                return;
            const target = item.state ? 'on' : 'off';
            this._busy = true;
            this._updateSensitivity();
            runCli(['vision', target], () => {
                this._busy = false;
                this.poll();
            });
        });
        this.menu.addMenuItem(this._visionSwitch);
        // Start insensitive: _visionSupported is false until the first
        // refresh confirms the running model can carry a vision component.
        this._updateSensitivity();

        this._orchItem = new PopupMenu.PopupMenuItem('Orchestrator: …');
        this._orchItem.connect('activate', () => {
            const on = this._orchestratorActive;
            runCli(['orchestrator', on ? 'off' : 'on'], () => this.poll());
        });
        this.menu.addMenuItem(this._orchItem);

        // LAN access and the API key. The toggle starts/stops the gateway on
        // :8741, which is the only way in from the network (every profile binds
        // :8731 to loopback). The key can be copied to the clipboard, rotated,
        // or cleared. Everything goes through superfast-switch, so the menu
        // holds no state of its own.
        this._keySub = new PopupMenu.PopupSubMenuMenuItem('API key: …');

        this._keyToggle = new PopupMenu.PopupMenuItem('Turn on / off');
        this._keyToggle.connect('activate', () => {
            runCli(['api-key', this._gatewayActive ? 'off' : 'on'], () => this.poll());
        });
        this._keySub.menu.addMenuItem(this._keyToggle);

        this._keyCopy = new PopupMenu.PopupMenuItem('Copy key to clipboard');
        this._keyCopy.connect('activate', () => {
            runCli(['api-key', 'show'], out => {
                const key = (out || '').trim();
                if (key) {
                    St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, key);
                    this._keySub.label.text = 'API key: copied';
                } else {
                    this._keySub.label.text = 'API key: not set';
                }
            });
        });
        this._keySub.menu.addMenuItem(this._keyCopy);

        this._keyNew = new PopupMenu.PopupMenuItem('Generate a new key');
        this._keyNew.connect('activate', () => {
            // `api-key set` prints the new key on stdout, so it can be copied
            // straight away.
            runCli(['api-key', 'set'], out => {
                const key = (out || '').trim();
                if (key)
                    St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, key);
                this.poll();
            });
        });
        this._keySub.menu.addMenuItem(this._keyNew);

        this._keyClear = new PopupMenu.PopupMenuItem('Clear key and stop the gateway');
        this._keyClear.connect('activate', () => runCli(['api-key', 'clear'], () => this.poll()));
        this._keySub.menu.addMenuItem(this._keyClear);

        this.menu.addMenuItem(this._keySub);

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
            // `superfast-switch status` prints "... api key: <set|not set>,
            // gateway <active|inactive> ...", parsed here so one call covers
            // the whole menu.
            const keySet = /api key:\s*set/.test(out);
            const gw = (out.match(/gateway (\w+)/) || [])[1] ?? 'inactive';
            this._gatewayActive = gw === 'active';
            this._keySub.label.text =
                `API key: ${this._gatewayActive ? 'on' : 'off'}${keySet ? '' : ' (none)'}`;

            this._modelSection.removeAll();
            this._modelItems = [];
            for (const p of PROFILES) {
                const label = `${p === active ? '● ' : '○ '}${p}`;
                const item = new PopupMenu.PopupMenuItem(label);
                item.connect('activate', () => {
                    this._busy = true;
                    this._updateSensitivity();
                    runCli(['use', p], () => {
                        this._busy = false;
                        this.poll();
                    });
                });
                this._modelSection.addMenuItem(item);
                this._modelItems.push(item);
            }

            // The switch line is "vision: supported=<yes|no> enabled=<yes|no>
            // profile=<name>". supported=no on the text-only profiles and when
            // nothing is running, which keeps the switch off and insensitive.
            this._visionSupported = /vision:.*supported=yes/.test(out);
            this._visionEnabled = /vision:.*enabled=yes/.test(out);
            this._syncing = true;
            this._visionSwitch.setToggleState(this._visionEnabled);
            this._syncing = false;
            this._updateSensitivity();
        });
    }

    // Enable or grey out the action items. A model restart (profile switch or
    // vision toggle) sets _busy, during which nothing else may be started; the
    // vision switch is additionally gated on the running model supporting it.
    _updateSensitivity() {
        if (this._visionSwitch) {
            this._visionSwitch.setSensitive(this._visionSupported && !this._busy);
            this._visionSwitch.label.text = this._visionSupported
                ? 'Vision'
                : 'Vision (not on this model)';
        }
        for (const it of this._modelItems)
            it.setSensitive(!this._busy);
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
