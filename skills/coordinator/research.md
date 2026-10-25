# Research behind the coordinator

Each entry: the finding, then what the skill does because of it. Adapt a rule only in a way that still
serves its finding.

## Capacity

**Working memory holds about four chunks** (Cowan 2001, *Behavioral and Brain Sciences* 24).
One card at a time; a card carries the decision plus at most three facts; the board lists names, not
detail.

**Extraneous load competes with the task** (Sweller 1988, *Cognitive Science* 12). Anything on screen
that does not serve the decision (IDs, tool output, logs, history) uses capacity the decision needs.
Bottom line first; depth only on request.

## Switching

**Switching tasks costs time, more so for complex tasks** (Rubinstein, Meyer & Evans 2001, *JEP: Human
Perception and Performance* 27; Monsell 2003, *Trends in Cognitive Sciences* 7).
Group items by shared context and never interleave groups.

**An unfinished task leaves attention residue that lowers performance on the next** (Leroy 2009,
*Organizational Behavior and Human Decision Processes* 109).
Close each card fully before opening the next. Parking counts as closing only with a written next step.

**Writing a specific plan for an unfinished goal reduces its pull on later tasks** (Masicampo &
Baumeister 2011, *Journal of Personality and Social Psychology* 101).
Parked items get a next step and a revisit time, said back to the human.

## Interruption

**Interrupted work gets done faster but with more stress and frustration** (Mark, Gudith & Klocke 2008,
CHI). **Interruptions at task boundaries cost less than mid-task** (Adamczyk & Bailey 2004, CHI; Iqbal &
Bailey 2008, CHI).
New events wait until the current card closes; only emergencies break in.

**Frequent alerts that need no action lead people to ignore alerts, real ones included** (Cvach 2012,
*Biomedical Instrumentation & Technology* 46, on clinical alarm fatigue).
Only actionable items reach the human.

## Forgetting and resumption

**Forgetting is steepest in the first hours and flattens after about a day** (Ebbinghaus 1885;
replicated by Murre & Dros 2015, *PLoS ONE* 10).
Refresher size follows the gap since last touch. Ties go to the freshest stream, whose refresh cost
is about to rise; an old stream costs much the same tomorrow.

**Goals decay unless retrieved, and resumption is faster when a cue to the goal and the next step is
at hand** (Altmann & Trafton 2002, *Cognitive Science* 26; Trafton, Altmann, Brock & Mintz 2003,
*International Journal of Human-Computer Studies* 58).
Every card states the goal, where it stands and the one thing needed.

**Programmers rarely resume an interrupted task within a minute and lean on notes of where they were**
(Parnin & Rugaber 2011, *Software Quality Journal* 19).
`coord-gist` and `coord-next` are those notes, kept for the human.

**Recall works best with cues that match how the memory was formed** (Tulving & Thomson 1973,
*Psychological Review* 80), and recognising is cheaper than recalling.
Quote the human's own words and use their names for things, never IDs or the agent's paraphrase.

## Recognising a stream

**Pictures are remembered better than words, and a named picture is stored in two codes** (Paivio
1971, *Imagery and Verbal Processes*; Nelson, Reed & Walling 1976, *JEP: Human Learning and Memory* 2).
Each stream carries an emoji beside its name. Because a cue present when a memory forms helps bring it
back (Tulving & Thomson, above), the motif appears everywhere the human meets the stream: the sidebar,
every card, the recap.

**Distinct items are remembered better than similar ones** (von Restorff 1933, *Psychologische
Forschung* 18). **One feature such as colour is found at a glance among many items; a combination of
features needs a serial search** (Treisman & Gelade 1980, *Cognitive Psychology* 12).
Motifs differ in kind and, where possible, in colour, so the human finds a stream in the sidebar
without reading titles.

**A cue linked to many memories retrieves each less well** (Watkins & Watkins 1975, *JEP: Human
Learning and Memory* 1). **Old associations interfere with new ones** (Underwood 1957, *Psychological
Review* 64).
One motif per stream, never shared, never changed, not reused within a month.

**Processing for meaning makes memories last longer** (Craik & Lockhart 1972, *Journal of Verbal
Learning and Verbal Behavior* 11).
A motif tied to the subject is preferred; distinctness wins when the two conflict.

## Decisions

**Decision time rises with the number of options** (Hick 1952, *Quarterly Journal of Experimental
Psychology* 4; Hyman 1953, *Journal of Experimental Psychology* 45).
A recommended default, three options at most, a one-word reply.

**Situation awareness has three levels: perceive, understand, project** (Endsley 1995, *Human
Factors* 37).
Cards and the board say what a status means and what happens next, not just the status.

## Throughput

**For one server, ordering jobs by weight over processing time minimises total weighted waiting**
(Smith 1956, *Naval Research Logistics Quarterly* 3).
Rank groups by agent work released per minute of human effort.

**Items in a system = arrival rate × time in system** (Little 1961, *Operations Research* 9).
With the human's throughput fixed, more agents in flight only lengthens each wait. Hence the
queue-growing warning and the advice to stop starting new work.

## Deliberately not used

- **"Decision fatigue" and ego depletion.** The parole-board study (Danziger, Levav & Avnaim-Pesso
  2011) is confounded by case ordering (Weinshall-Margel & Shapard 2011), and ego depletion failed a
  large multi-lab replication (Hagger et al. 2016). Ordering is not built on saving willpower.
- **The Zeigarnik effect** (better memory for unfinished tasks) replicates inconsistently. The skill
  relies on the plan-making finding above instead.
- **Colour alone as the motif.** Red-green colour deficiency affects about 8% of men of Northern
  European descent (Birch 2012, *Journal of the Optical Society of America A* 29), and few colours stay
  distinct at sidebar size. Emoji differ in shape as well as colour.
