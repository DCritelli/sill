"""Each mutant of ClientSession.swift or ClientPairing.swift must fail the client-session check (main.swift).
usage: mutants.py"""
import glob, os, subprocess, sys
SP = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(SP, "..", "..", ".."))   # the repository
OUT = os.path.join(ROOT, ".build", "checks", "client-session")   # the mutants' sources and binaries
os.makedirs(OUT, exist_ok=True)
FILES = ["Sources/SillClient/ClientSession.swift", "Sources/SillClient/ClientPairing.swift", "Sources/SillClient/ClientConnection.swift"]
ORIG = {f: open(os.path.join(ROOT, f)).read() for f in FILES}
# SavedMacs.swift imports StreamProtocol, which is one module with this check (run.sh does the same).
SAVED = os.path.join(OUT, "SavedMacs.swift")
GOODBYE = os.path.join(OUT, "GoodbyePolicy.swift")
open(GOODBYE, "w").write("".join(l for l in open(os.path.join(ROOT, "iOSClient/GoodbyePolicy.swift")) if l.strip() != "import StreamProtocol"))
open(SAVED, "w").write("".join(l for l in open(os.path.join(ROOT, "iOSClient/SavedMacs.swift")) if l.strip() != "import StreamProtocol"))
P = "Sources/SillClient/ClientPairing.swift"
K = "Sources/SillClient/ClientConnection.swift"
S = "Sources/SillClient/ClientSession.swift"
MUTANTS = {
    "C1 no hello": [("            send(.hello, Wire.encode(hello))\n", "")],
    "C2 the hello after the start": [
        ("            send(.hello, Wire.encode(hello))\n            connection.start(queue: queue)\n",
         "            connection.start(queue: queue)\n            queue.asyncAfter(deadline: .now() + 0.3) { self.send(.hello, Wire.encode(self.hello)) }\n")],
    "C3 the last Window, not the first": [("list.windows.first.map", "list.windows.last.map")],
    "C4 no Desktop for an empty list": [("list.windows.first.map { .window($0.id) } ?? .desktop", "list.windows.first.map { .window($0.id) } ?? .none")],
    "C5 the Desktop pick ignored": [("        case .desktop: source = .desktop\n", "        case .desktop: source = list.windows.first.map { .window($0.id) } ?? .desktop\n")],
    "C6 every list picks": [("            if picked == nil { choose(from: list) }", "            choose(from: list)")],
    "C7 no Viewport": [("        send(.selectSource, Wire.encode(source))\n        send(.viewport, Wire.encode(viewport))\n", "        send(.selectSource, Wire.encode(source))\n")],
    "C8 the Viewport before the pick": [
        ("        send(.selectSource, Wire.encode(source))\n        send(.viewport, Wire.encode(viewport))\n",
         "        send(.viewport, Wire.encode(viewport))\n        send(.selectSource, Wire.encode(source))\n")],
    "C9 the keyframe flag dropped": [("            onFrame?(payload, header.isKeyframe)", "            onFrame?(payload, true)")],
    "C10 no parameter sets": [("            if let sets = ParameterSets(encoded: payload) { onParameterSets?(sets) }", "            break")],
    "C11 no pings": [("                    startPinging()\n", "")],
    "C12 the end not reported": [("        connection.cancel()\n        onEnd?(why)\n", "        connection.cancel()\n")],
    "C13 stop() reports the end": [
        ("            guard running else { return }\n            running = false\n            pingTimer?.cancel()\n            connection.cancel()\n        }\n",
         "            guard running else { return }\n            end(\"stopped\")\n        }\n")],
    "C15 the list not handed on": [("            onWindowList?(list)\n", "")],
    "C16 no cursor shape handed on": [("            onCursorShape?(payload)\n", "            break\n")],
    "C17 only the first input sent": [("            for event in events { send(.input, Wire.encode(event)) }", "            send(.input, Wire.encode(events[0]))")],
    "C18 input sent in reverse": [("            for event in events { send(.input, Wire.encode(event)) }", "            for event in events.reversed() { send(.input, Wire.encode(event)) }")],
    "C19 the session's pin ignored": [("            guard let pin else { return fp != nil }\n            return fp == pin\n        }, queue: verifyQueue)", "            return fp != nil\n        }, queue: verifyQueue)")],
    "C20 the session over sill-pair/1": [("role: .client(alpn: RemoteTLS.sessionALPN)", "role: .client(alpn: RemoteTLS.pairingALPN)")],
    # ClientPairing.swift (DCritelli/sill#2): each edit is (file, old, new) there.
    "P1 a typo sent to the Host": [(P, "            if case .code(let text) = request, case .failure(let problem) = PairingCode.check(text) {", "            if case .code(let text) = request, case .failure(let problem) = PairingCode.check(text), text.isEmpty {")],
    "P2 proof_M not checked": [(P, "              PairingProof.isValidMacProof(proofM, key: key, macFingerprint: fpMac, deviceFingerprint: identity.fingerprint),\n", "              !proofM.isEmpty,\n")],
    "P3 the Mac ID not checked": [(P, "              r.macID == MacID.make(fingerprint: fpMac),\n", "")],
    "P4 the pairing pin ignored": [(P, "            guard let pin else { return fp != nil }\n            return fp == pin\n        }, queue: queue)", "            return fp != nil\n        }, queue: queue)")],
    "P5 no tries left in the words": [(P, "Check the code on \\(mac). \\(left)\\u{00A0}tr\\(left == 1 ? \"y\" : \"ies\") left.", "Check the code on \\(mac).")],
    "P6 expired read as closed": [(P, "            case PairResult.expired?:\n", "            case \"never\"?:\n")],
    "P7 the Host's own words ignored": [(P, "            if let words = r.unknownReasonMessage { return words }\n            switch r.reason {", "            switch r.reason {")],
    "P8 only the first target tried": [(P, "            case .waiting, .failed:\n                giveUp(id)", "            case .waiting, .failed:\n                finish(.failed(Words.noAnswer(macName)))")],
    "P9 the proof binds the keys swapped": [(P, "PairingProof.deviceProof(key: $0, deviceFingerprint: fpDevice, macFingerprint: fpMac)", "PairingProof.deviceProof(key: $0, deviceFingerprint: fpMac, macFingerprint: fpDevice)")],
    "P10 not saved as a TLS door": [(P, "lastRoute: nil, homeTLS: true, revoked: nil)", "lastRoute: nil, homeTLS: nil, revoked: nil)")],
    "P11 the Bonjour name not saved": [(P, "            bonjourName = name\n", "            typed = []\n")],
    "P12 the typed address not kept": [(P, "            typed = [MacAddress(host: text, port: Int(port.rawValue), kind: MacAddress.lan, via: \"Typed\")]", "            typed = [MacAddress(host: text, port: nil, kind: MacAddress.lan, via: \"Typed\")]")],
    "P13 the ask carries the code method": [(P, "            method = PairRequest.ask\n", "            method = PairRequest.code\n")],
    "P14 the ask's key not handed back": [(P, "            return .asked(reason: reason, fingerprint: fpMac, endpoint: endpoint)", "            return .asked(reason: reason, fingerprint: identity.fingerprint, endpoint: endpoint)")],
    "P15 the link's secret not the key": [(P, "            makeKey = { _ in PairingProof.qrKey(secret: link.secret) }", "            makeKey = { _ in PairingProof.qrKey(secret: Data(link.secret.reversed())) }")],
    "P16 the device's name not sent": [(P, "let request = PairRequest(method: method, proof: proof, name: deviceName, model: model)", "let request = PairRequest(method: method, proof: proof, name: \"Mac\", model: model)")],
    # ClientConnection.swift and the session's resume (DCritelli/sill#9).
    "K1 a final goodbye redialed": [(K, "            guard outcome.reconnect else { stopFor(outcome.text, storeLink: outcome.storeLink); return }\n", "")],
    "K2 the goodbye ignored": [(K, "            self.goodbye = $0\n", "")],
    "K3 the reason not surfaced": [(K, "stopFor(outcome.text, storeLink: outcome.storeLink)", "stopFor(\"Disconnected.\", storeLink: outcome.storeLink)")],
    "K4 the App Store offer dropped": [(K, "stopFor(outcome.text, storeLink: outcome.storeLink)", "stopFor(outcome.text, storeLink: false)")],
    "K5 no redial after a drop": [(K, "        queue.asyncAfter(deadline: .now() + wait) { [weak self] in\n            guard let self, self.running, self.generation == mine else { return }\n            self.launch()\n        }\n", "")],
    "K6 Reconnecting not reported": [(K, "        onState?(.reconnecting(attempt: failures))\n", "")],
    "K7 never up, still redialed": [(K, "        guard everConnected else {\n", "        guard everConnected || running else {\n")],
    "K8 never gives up": [(K, "        guard failures < maxAttempts else {\n", "        guard failures < maxAttempts * 1000 else {\n")],
    "K9 the first pick again": [(K, "pick: lastSource.map { .resume($0) } ?? pick", "pick: pick")],
    "K10 the Source follows the pick only": [(K, "            if list.active != .none { self.lastSource = list.active }\n", "")],
    "K11 redials after stop()": [(K, "            running = false\n            generation += 1\n            current?.stop()", "            current?.stop()")],
    "K12 the Host looked up once": [(K, "        guard let target = dial() else {", "        guard let target = (dialled ?? dial()) else {"), (K, "    private var generation = 0\n", "    private var generation = 0\n    private var dialled: Dial?\n"), (K, "        goodbye = nil\n        attach?(session)", "        dialled = target\n        goodbye = nil\n        attach?(session)")],
    "K14 the wait never grows": [(K, "        schedule[min(max(attempt, 0), schedule.count - 1)]", "        schedule[0]")],
    "R1 a gone Window resumed": [(S, "        case .resume(.window(let id)) where list.windows.contains { $0.id == id }: source = .window(id)\n", "        case .resume(.window(let id)): source = .window(id)\n")],
    "R2 the Desktop not resumed": [(S, "        case .resume: source = .desktop\n", "        case .resume: source = list.windows.first.map { .window($0.id) } ?? .desktop\n")],
    "R3 the goodbye not handed on": [(S, "if let goodbye = Wire.decode(Goodbye.self, from: payload) { onGoodbye?(goodbye) }", "break")],
    # Not a mutant here: dropping `end`'s own `guard running`. The session cancels its connection as
    # it ends, so no second end can arrive (the reader stops on `running`, a cancelled connection
    # reports .cancelled, which is ignored); the guard stays for a stack that does.
}
caught = 0
for name, edits in MUTANTS.items():
    srcs = dict(ORIG)
    applied = True
    for edit in edits:
        f, old, new = edit if len(edit) == 3 else (FILES[0],) + tuple(edit)
        n = srcs[f].count(old)
        if n != 1:
            print(f"{name}: NOT APPLIED (pattern found {n} times)")
            applied = False
            break
        srcs[f] = srcs[f].replace(old, new)
    if not applied: continue
    paths = []
    for f, text in srcs.items():
        path = os.path.join(OUT, os.path.basename(f))
        open(path, "w").write(text)
        paths.append(path)
    sources = paths + [SAVED, GOODBYE, os.path.join(ROOT, "iOSClient/MessageReader.swift")] + sorted(glob.glob(os.path.join(ROOT, "Sources/StreamProtocol/*.swift")))
    b = subprocess.run(["swiftc", "-O"] + sources + [os.path.join(SP, "main.swift"), "-o", os.path.join(OUT, "mutant")],
                       capture_output=True, text=True)
    if b.returncode != 0:
        print(f"{name}: DOES NOT COMPILE\n{b.stderr[:600]}"); continue
    try:
        r = subprocess.run([os.path.join(OUT, "mutant")], capture_output=True, text=True, timeout=120)
        failed = [l[5:] for l in r.stdout.splitlines() if l.startswith("FAIL")]
        ok = r.returncode != 0
        detail = f"{len(failed)} failing, e.g. {failed[:2]}" if failed else f"exit status {r.returncode}"
    except subprocess.TimeoutExpired:
        ok, detail = True, "timed out (120 s)"
    caught += ok
    print(f"{'caught' if ok else 'MISSED'} {name}: {detail}")
print(f"{caught} of {len(MUTANTS)} mutants caught")
sys.exit(0 if caught == len(MUTANTS) else 1)
