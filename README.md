# DecentContest

Transmog contests for World of Warcraft: Forever. Anyone with the addon can host, judge or compete.
Judges score every contestant on three categories, and the highest overall score wins.

## Install
1. Copy this addon into your WoW Forever client's `Interface\AddOns` folder and name the folder
   **`DecentContest`** (it must match `DecentContest.toc`). The folder should contain
   `DecentContest.toc` and `DecentContest.lua`.
2. Restart the game or `/reload`. If it shows as "out of date" on the character screen,
   tick **Load out of date AddOns** or update the `## Interface:` line in `DecentContest.toc`
   (in game, `/dump select(4, GetBuildInfo())` prints the right number).

Everyone who wants to judge or compete needs the addon. Players without it can still watch, and
the host's chat announcements tell them where to get it.

The minimap clothing icon opens the contest window with a left-click and Settings with a
right-click. Drag it around the minimap to reposition it. Hide it from Settings or with
`/dcon minimap`.

## How a contest works
1. **Host:** type `/dcon`, enter a **theme** (e.g. "Pirates of the Vale"), pick **Group** or
   **Guild** and click **Open Lobby**. The host's group or guild chat gets an announcement.
2. **Lobby:** everyone with the addon sees the contest pop up. Choose one of the two role cards:
   **Judge** to score each contestant, or **Contestant** to compete. The lobby shows both role lists
   before the host starts, so everyone can confirm the assignments. Anyone can switch roles or
   **Leave** while the lobby is open.
   The host can join as a judge or contestant too, or just run the contest.
3. **Start:** the host clicks **Start Contest** (needs at least 1 judge and 1 contestant).
   - Every player is told **who the judges are**, both in the window and in chat.
   - **Judges and contestants are locked in** until the contest finishes. Nobody can join, leave or
     switch roles.
4. **Judging:** each judge gets a tab for every contestant. In each tab:
   - A live 3D preview of the contestant (drag to rotate, scroll to zoom) and an **Inspect** button.
   - A **1-10 slider and number box** for each category:
     - **Theme & Cohesion**
     - **Color Coordination**
     - **Creativity**
   - A check mark appears on the tab once all three are scored. Use **Prev / Next** or click tabs.
   - Your scores are saved as you go, so a `/reload` doesn't lose them.
   - When every contestant is scored, click **Submit Final Scores**. Submitted scores can't be changed.
5. **Results:** when the last judge submits, the host's addon adds up every judge's points and
   everyone sees the standings. The **highest overall total wins**. Equal totals share first place.
   The host can post the top 3 to chat with **Announce Top 3**.

Contestants and spectators see each judge's progress (**scoring...** / **Submitted**) while they wait.
Individual judges' scores stay private. Only the totals are shown.

### Scoring
Each judge gives each contestant up to **30 points** (3 categories x 10).
A contestant's **overall score** is the sum of every judge's points. The results table shows
the total for each category, the overall total, and the average per judge.

### Host controls
- **End Judging:** finish early with only the judges who have already submitted. Use this if a judge
  goes AFK or disconnects.
- **Cancel Contest:** stop with no winner.
- If the host reloads or disconnects and comes back, the contest resumes. Clients that reload
  catch up automatically.

## Tips
- The 3D preview and Inspect need the contestant to be **in your group and in visible range**.
  For guild contests outside a group, target the contestant and press **Refresh**.
- Contests run over hidden addon messages. Blizzard doesn't let trial and veteran accounts send them,
  and some instances block them. If you see a "could not send" warning, that's why.
- Hosting while not in a group/guild runs a **local test mode** that only you can see.

## Commands
| Command | What it does |
|---|---|
| `/dcon` | Toggle the window |
| `/dcon host <theme>` | Open a lobby with that theme |
| `/dcon start` / `/dcon end` / `/dcon cancel` | Host: start, end judging early, cancel |
| `/dcon history` | Recent contests and their winners |
| `/dcon sync` | Ask the host to resend the current contest |
| `/dcon reset` | Clear a stuck contest on your side (cancels it if you're the host) |
| `/dcon announce` | Toggle chat announcements when hosting |
| `/dcon popup` | Toggle opening the window when someone opens a contest |
| `/dcon settings` | Open the settings window |
| `/dcon minimap` | Show or hide the minimap icon |
| `/dcon scale <0.6-1.5>` / `/dcon resetpos` | Window size / position |

## Settings

The Settings window includes **Use Blizzard-style window**, which switches between the game's
marble/rock panels with native button artwork and the purple DecentContest theme. It also controls
position locking, the minimap icon, chat announcements, lobby popups, show-on-login, and window
scale. Hover the controls and role cards for descriptions. Settings are saved in `DecentContestDB`.

Saved per account in `DecentContestDB`: settings, contest history, in-progress judge scores and
the contest you're hosting.
