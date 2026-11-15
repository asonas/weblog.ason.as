---- MODULE DraftSync ----
\* One editor tab saves a draft to the device (IndexedDB) and to the server,
\* while another device may change the title on the server.
\* Every action names the code it stands for. See SKILL.md, 対応表.
EXTENDS Naturals

CONSTANTS MaxEdits, MaxRev

None == "none"
Init0 == "initial"
Mine == "mine"
Theirs == "theirs"

\* draftSession.ts Flight. `receipt` is TRUE once the server has stored a
\* draft_updates row for this update_id; rr/rt are that receipt's title metadata.
NoFlight == [on |-> FALSE, body |-> 0, title |-> None, rev |-> 0,
             receipt |-> FALSE, rt |-> None, rr |-> 0]

VARIABLES
  typed,        \* body revisions made in the editor (DraftSession.revision)
  onDevice,     \* body revisions written to IndexedDB (persistedRevision)
  onServer,     \* body revisions the server holds (draft_updates)
  lTitle,       \* this.metadata.title
  baseTitle,    \* this.serverMetadata.title.value
  baseRev,      \* this.serverMetadata.title.revision
  conflict,     \* this.conflicts.title is set
  cTitle, cRev, \* this.conflicts.title (value, revision)
  sTitle, sRev, \* articles.metadata title on the server
  flight,       \* this.flight
  sending,      \* uploadFlight is on the wire
  net,          \* "up" | "down"
  status,       \* this.serverStatus
  applies,      \* times the server applied the current flight
  clobbered     \* the other device's title was replaced without the author choosing it

vars == <<typed, onDevice, onServer, lTitle, baseTitle, baseRev, conflict, cTitle,
          cRev, sTitle, sRev, flight, sending, net, status, applies, clobbered>>
local == <<lTitle, baseTitle, baseRev, conflict, cTitle, cRev>>

Init ==
  /\ typed = 0 /\ onDevice = 0 /\ onServer = 0
  /\ lTitle = Init0 /\ baseTitle = Init0 /\ baseRev = 0
  /\ conflict = FALSE /\ cTitle = None /\ cRev = 0
  /\ sTitle = Init0 /\ sRev = 0
  /\ flight = NoFlight
  /\ sending = FALSE
  /\ net = "up"
  /\ status = "saved"
  /\ applies = 0
  /\ clobbered = FALSE

Max(a, b) == IF a > b THEN a ELSE b

\* mergeMetadata(incoming) for the title, against the server value (st, sr).
Merge(lt, bt, br, cf, ct, cr, st, sr) ==
  IF sr < br THEN [l |-> lt, b |-> bt, r |-> br, cf |-> cf, ct |-> ct, cr |-> cr]
  ELSE IF (~cf /\ lt = bt) \/ lt = st
    THEN [l |-> st, b |-> st, r |-> sr, cf |-> FALSE, ct |-> ct, cr |-> cr]
  ELSE IF sr > br
    THEN [l |-> lt, b |-> bt, r |-> br, cf |-> TRUE, ct |-> st, cr |-> sr]
  ELSE [l |-> lt, b |-> bt, r |-> br, cf |-> cf, ct |-> ct, cr |-> cr]

SetLocal(m) ==
  /\ lTitle' = m.l /\ baseTitle' = m.b /\ baseRev' = m.r
  /\ conflict' = m.cf /\ cTitle' = m.ct /\ cRev' = m.cr

\* catchUp(): serverStatus after merging.
StatusAfter(m, body) ==
  IF m.cf THEN "conflict"
  ELSE IF typed > body \/ m.l # m.b THEN "unsent"
  ELSE "saved"

\* ---------- The author and the world ----------

\* changed(): every body edit bumps the revision and marks unsent changes.
YouType ==
  /\ typed < MaxEdits
  /\ typed' = typed + 1
  /\ status' = "unsent"
  /\ UNCHANGED <<onDevice, onServer, flight, sending, net, applies, clobbered, sTitle, sRev>>
  /\ UNCHANGED local

\* setMetadata({title}) -> changed().
YouChangeTheTitle ==
  /\ lTitle # Mine
  /\ lTitle' = Mine
  /\ status' = "unsent"
  /\ UNCHANGED <<typed, onDevice, onServer, baseTitle, baseRev, conflict, cTitle, cRev>>
  /\ UNCHANGED <<sTitle, sRev, flight, sending, net, applies, clobbered>>

\* persist(): the IndexedDB write for the latest revision finishes.
TheDeviceWriteFinishes ==
  /\ onDevice < typed
  /\ onDevice' = typed
  /\ UNCHANGED <<typed, onServer, flight, sending, net, status, applies, clobbered, sTitle, sRev>>
  /\ UNCHANGED local

\* Another device's DraftStore#append_data with a fresh expected_revision.
TheOtherDeviceChangesTheTitle ==
  /\ sTitle # Theirs
  /\ sTitle' = Theirs
  /\ sRev' = sRev + 1
  /\ UNCHANGED <<typed, onDevice, onServer, flight, sending, net, status, applies, clobbered>>
  /\ UNCHANGED local

TheNetworkDrops ==
  /\ net = "up" /\ net' = "down"
  /\ UNCHANGED <<typed, onDevice, onServer, flight, sending, status, applies, clobbered, sTitle, sRev>>
  /\ UNCHANGED local

TheNetworkReturns ==
  /\ net = "down" /\ net' = "up"
  /\ UNCHANGED <<typed, onDevice, onServer, flight, sending, status, applies, clobbered, sTitle, sRev>>
  /\ UNCHANGED local

\* ---------- syncLocked() ----------

\* syncLocked up to uploadFlight. It returns early until persist() has caught
\* up. Without a flight it runs catchUp (mergeMetadata), stops on a metadata
\* conflict, and otherwise builds a flight with expected_revision = baseRev.
SyncStarts ==
  /\ onDevice = typed
  /\ net = "up"
  /\ ~sending
  /\ LET m == IF flight.on THEN [l |-> lTitle, b |-> baseTitle, r |-> baseRev,
                                 cf |-> conflict, ct |-> cTitle, cr |-> cRev]
              ELSE Merge(lTitle, baseTitle, baseRev, conflict, cTitle, cRev, sTitle, sRev)
         newFlight == [on |-> TRUE, body |-> typed,
                       title |-> IF m.l # m.b THEN m.l ELSE None,
                       rev |-> m.r, receipt |-> FALSE, rt |-> None, rr |-> 0]
         pending == typed > onServer \/ m.l # m.b
     IN /\ SetLocal(m)
        /\ IF m.cf /\ ~flight.on
             THEN /\ status' = "conflict"
                  /\ UNCHANGED <<flight, applies, sending>>
           ELSE IF flight.on
             THEN /\ status' = "saving"
                  /\ sending' = TRUE
                  /\ UNCHANGED <<flight, applies>>
           ELSE IF pending
             THEN /\ flight' = newFlight
                  /\ applies' = 0
                  /\ status' = "saving"
                  /\ sending' = TRUE
           ELSE /\ status' = "saved"
                /\ UNCHANGED <<flight, applies, sending>>
  /\ UNCHANGED <<typed, onDevice, onServer, sTitle, sRev, net, clobbered>>

\* sync() with the network down: catchUp's request fails (status 0) and the
\* catch block shows the transient error. A flight, if any, is kept.
TheSyncCannotReachTheServer ==
  /\ onDevice = typed
  /\ net = "down"
  /\ ~sending
  /\ status' = "unconfirmed"
  /\ UNCHANGED <<typed, onDevice, onServer, flight, sending, net, applies, clobbered, sTitle, sRev>>
  /\ UNCHANGED local

\* ---------- Server side of uploadFlight ----------

\* DraftStore#merge_metadata accepts the title only when expected_revision
\* equals the current revision. A stored receipt short-circuits the check.
TitleFresh == flight.receipt \/ flight.title = None \/ flight.rev = sRev

\* DraftStore#begin_upload / #commit_upload / #append_data: an update_id with a
\* stored receipt returns that receipt and is not applied again.
Apply ==
  IF flight.receipt
    THEN UNCHANGED <<onServer, sTitle, sRev, applies, clobbered>>
    ELSE /\ onServer' = Max(onServer, flight.body)
         /\ applies' = applies + 1
         /\ IF flight.title # None
              THEN /\ sTitle' = flight.title
                   /\ sRev' = sRev + 1
                   /\ clobbered' = (clobbered \/ (sTitle = Theirs /\ baseTitle # Theirs))
              ELSE UNCHANGED <<sTitle, sRev, clobbered>>

\* The receipt's title metadata: stored, or the server state right after Apply.
ReceiptTitle == IF flight.receipt THEN flight.rt ELSE sTitle'
ReceiptRev == IF flight.receipt THEN flight.rr ELSE sRev'

\* syncLocked after a matching receipt: adopt receipt.metadata as
\* serverMetadata, adopt its title locally when the flight did not carry the
\* title and the local title still equals the old base, drop the flight, then
\* catchUp(true) merges the current server title.
TheUploadSucceeds ==
  /\ sending /\ flight.on /\ net = "up"
  /\ TitleFresh
  /\ Apply
  /\ sending' = FALSE
  /\ flight' = NoFlight
  /\ LET lt == IF flight.title = None /\ lTitle = baseTitle THEN ReceiptTitle ELSE lTitle
         m == Merge(lt, ReceiptTitle, ReceiptRev, conflict, cTitle, cRev, sTitle', sRev')
     IN /\ SetLocal(m)
        /\ status' = StatusAfter(m, Max(onServer, flight.body))
  /\ UNCHANGED <<typed, onDevice, net>>

\* The server stored the update, but the reply never reaches the tab. The flight
\* stays in IndexedDB with the same update_id and is resent later.
TheUploadIsAppliedButTheReplyIsLost ==
  /\ sending /\ flight.on /\ ~flight.receipt /\ net = "up"
  /\ TitleFresh
  /\ Apply
  /\ sending' = FALSE
  /\ flight' = [flight EXCEPT !.receipt = TRUE, !.rt = sTitle', !.rr = sRev']
  /\ status' = "unconfirmed"
  /\ UNCHANGED <<typed, onDevice, net>>
  /\ UNCHANGED local

\* uploadFlight fails with status 0; the catch block schedules a retry.
TheUploadDoesNotArrive ==
  /\ sending /\ flight.on /\ net = "down"
  /\ sending' = FALSE
  /\ status' = "unconfirmed"
  /\ UNCHANGED <<typed, onDevice, onServer, flight, net, applies, clobbered, sTitle, sRev>>
  /\ UNCHANGED local

\* 409 "Metadata conflict:": the transaction is rejected as a whole, the flight
\* is dropped (its body edits stay in this.pending), and catchUp() merges.
TheServerRejectsTheStaleTitle ==
  /\ sending /\ flight.on /\ net = "up"
  /\ ~TitleFresh
  /\ sending' = FALSE
  /\ flight' = NoFlight
  /\ LET m == Merge(lTitle, baseTitle, baseRev, conflict, cTitle, cRev, sTitle, sRev)
     IN /\ SetLocal(m)
        /\ status' = StatusAfter(m, onServer)
  /\ UNCHANGED <<typed, onDevice, onServer, sTitle, sRev, net, applies, clobbered>>

\* ---------- resolveMetadata(field, choice) ----------
\* Ignored while a flight exists. The stored conflict becomes serverMetadata.

YouKeepTheOtherTitle ==
  /\ conflict /\ ~flight.on
  /\ lTitle' = cTitle /\ baseTitle' = cTitle /\ baseRev' = cRev
  /\ conflict' = FALSE
  /\ status' = "unsent"
  /\ UNCHANGED <<cTitle, cRev, typed, onDevice, onServer, sTitle, sRev, flight, sending, net, applies, clobbered>>

YouKeepYourTitle ==
  /\ conflict /\ ~flight.on
  /\ baseTitle' = cTitle /\ baseRev' = cRev
  /\ conflict' = FALSE
  /\ status' = "unsent"
  /\ UNCHANGED <<lTitle, cTitle, cRev, typed, onDevice, onServer, sTitle, sRev, flight, sending, net, applies, clobbered>>

Next ==
  \/ YouType \/ YouChangeTheTitle \/ TheDeviceWriteFinishes
  \/ TheOtherDeviceChangesTheTitle \/ TheNetworkDrops \/ TheNetworkReturns
  \/ SyncStarts \/ TheSyncCannotReachTheServer
  \/ TheUploadSucceeds \/ TheUploadIsAppliedButTheReplyIsLost
  \/ TheUploadDoesNotArrive \/ TheServerRejectsTheStaleTitle
  \/ YouKeepTheOtherTitle \/ YouKeepYourTitle

Spec == Init /\ [][Next]_vars

\* ---------- Rules ----------

\* 「サーバーに保存済み」と表示しているなら、本文と作者のタイトルはサーバーにある
\* （その後に別端末がタイトルを変えた場合を除く）。
SavedMeansOnServer ==
  status = "saved" => onServer = typed /\ (lTitle = sTitle \/ sRev > baseRev)
\* サーバーにある本文は、端末にも書き終えている。
DeviceFirst == onServer <= onDevice
\* 送信を再試行しても、同じ変更を二度当てない。
AppliedOnce == applies <= 1
\* 別端末で変えたタイトルを、作者が選ばずに上書きしない。
NoSilentOverwrite == ~clobbered

\* Model bound: the server title changes at most MaxRev times.
Bound == sRev <= MaxRev
====
