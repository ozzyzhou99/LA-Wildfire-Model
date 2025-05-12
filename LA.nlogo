extensions [ gis table ]

breed [ responders responder ]
responders-own [
  target-center
  destination-path
  path-index
  rescue-count
  mode ; "rescue" or "evacuate"
  rescue-speed
  distance-to-move
]

globals [
  house-raster street-raster sea-raster
  house-table street-table sea-table
  data-loaded?
  social-radius           ;; radius of infection
  contagion-matrix        ;; Matrix of emotional contagion coefficients
  tracked-turtle
  fire-centers     ;; Record initial fire patch list
  fire-radius      ;; Current fire radius
  fire-speed-patch-per-tick
]

patches-own [
  parent-patch g h f
  travel-cost is-fire? is-exit?
]

breed [ evacuees evacuee ]
evacuees-own [
  evac-path
  path-index
  waiting?
  income-level        ;; 0 = low, 0.5 = mid, 1 = high
  emotion-level       ;; continuous: "p"
  behavior            ;; state: "calm", "anxious", "panic"
  emotion-state       ;; duplicate of behavior for clarity
  social-influence
  evac-speed
  distance-to-move

  route-switch-count  ;; path recalculations
  stuck-duration      ;; ticks frozen
  exposure-flag       ;; 1 if touched fire
]



;;;========================
;;; Initialization and Setup
;;;========================

to load-data
  set house-raster gis:load-dataset "data/house_sub.asc"
  set street-raster gis:load-dataset "data/street_sub.asc"
  set sea-raster gis:load-dataset "data/sea.asc"
  gis:set-world-envelope gis:envelope-of house-raster
  set house-table table:make
  set street-table table:make
  set sea-table table:make
  set data-loaded? true
  ask patches [
    let key (list pxcor pycor)
    table:put house-table  key gis:raster-sample house-raster key
    table:put street-table key gis:raster-sample street-raster key
    table:put sea-table key gis:raster-sample sea-raster key
  ]
end

to setup
  no-display
  load-data
  set social-radius 5
  setup-contagion-matrix

  ask evacuees [ die ]
  ask responders [ die ]

  setup-patches
  setup-fires

  ask patches [ set plabel "" ]
  ask patches with [ is-exit? ] [ set plabel "exit" ]

  reset-ticks

  setup-evacuees
  setup-responders

  if tracked-income-group = "low"  [ set tracked-turtle one-of evacuees with [income-level = 0] ]
  if tracked-income-group = "mid"  [ set tracked-turtle one-of evacuees with [income-level = 0.5] ]
  if tracked-income-group = "high" [ set tracked-turtle one-of evacuees with [income-level = 1] ]

  set fire-speed-patch-per-tick fire-speed-kmph * 100 / 3600
  display
end


to setup-contagion-matrix
  ;; contagion-matrix[i][j]: contagion strength of neighbor's emotion i to self's emotion j
  ;; Mood Index: 0=calm,1=panic,2=anxious
  set contagion-matrix
  (list
    (list 0.1  0.2  0.3)   ;; neighbor=calm
    (list 0.4  0.1  0.5)   ;; neighbor=panic
    (list 0.2  0.3  0.1)   ;; neighbor=anxious
  )
end

to setup-patches
  ask patches [
    set is-fire? false
    set is-exit? false
    set pcolor white
    set travel-cost 999
    let key (list pxcor pycor)
    let hv table:get house-table key
    let sv table:get street-table key
    let seav table:get sea-table key
    if seav = 2 [
      set pcolor blue
      set travel-cost 999
      stop
    ]

    if hv = false and sv = false [ stop ]
    if hv = 79018  [ set pcolor grey   set travel-cost 10 ]
    if hv = 159079 [ set pcolor orange set travel-cost 10 ]
    if hv = 159219 [ set pcolor yellow set travel-cost 10 ]
    if hv = 217893 [ set pcolor violet set travel-cost 10 ]
    if hv = 999999 [ set pcolor green  set travel-cost 1 set is-exit? true ]
    if sv = 1      [ set pcolor black  set travel-cost 1 ]
    if sv = 0      [ set pcolor gray + 2 set travel-cost 2 ]
  ]
end


to setup-fires
  ifelse random-fire? [
    ;; Random fire centers (as before)
    set fire-centers n-of random-fire-count patches with [ not (pcolor = blue) ]
  ] [
    ;; Fire starts from house patches with value = 3
    set fire-centers patches with [
      table:get house-table (list pxcor pycor) = 3 and not (pcolor = blue)
    ]
  ]

  ;; Initial fire radius
  set fire-radius 10

  ;; Mark burning patches
  ask patches [
    if any? fire-centers with [ distance myself <= fire-radius ] [
      set is-fire?    true
      set pcolor      red
      set travel-cost 999
    ]
  ]
end


to spread-fire
  set fire-radius fire-radius + fire-speed-patch-per-tick
  ;; Mark newly burned patches
  ask patches with [ not is-fire? ] [
    if any? fire-centers with [ distance myself <= fire-radius ] [
      set is-fire?    true
      set pcolor      red
      set travel-cost 999
    ]
  ]
end

;;;========================
;;; Generate Agents
;;;========================

to setup-evacuees
  let low    patches with [table:get house-table (list pxcor pycor) = 79018]
  let mid    patches with [member? table:get house-table (list pxcor pycor) [159079 159219]]
  let high   patches with [table:get house-table (list pxcor pycor) = 217893]
  let exits  patches with [plabel = "exit"]
  let roads  patches with [travel-cost = 2 and not is-fire?]

  let groups (list low mid high)
  let colors (list grey orange violet)
  let lvls   (list 0 0.5 1)
  let counts (list low-income-count mid-income-count high-income-count)
  let grouped-data (map list groups colors lvls counts)

  foreach grouped-data [ triple ->
    let group item 0 triple
    let col   item 1 triple
    let lvl   item 2 triple
    let how-many item 3 triple

    create-evacuees how-many [
      move-to one-of group
      set shape "car"
      set size 8
      set color col
      set path-index 0
      set waiting? false
      set income-level lvl
      set behavior "calm"
      set social-influence 0

      ;; Path planning + route-switch tracking
      let target-road min-one-of roads [ distance myself ]
      let destination one-of exits
      set evac-path sentence (list target-road) (a-star-path target-road destination)
      set route-switch-count 1  ;; first path

      ;; Emotion model
      compute-emotion
      set emotion-state behavior

      ;; Time trackers
      set stuck-duration 0
      set exposure-flag 0

      ;; Driving speed setup: 10 km/h → 0.278 patch/sec
      set evac-speed 10 / 3.6 / 10
      set distance-to-move 0
    ]
  ]
end


to setup-responders
  let exits patches with [is-exit?]
  create-responders responder-count [
    set shape "car"
    set size 8
    set color blue
    move-to one-of exits
    set rescue-count 0
    set mode "rescue"
    choose-new-destination

    ;; Driving speed: 45 mph → 2.012 patch/sec
    set rescue-speed 45 * 1609.34 / 3600 / 10
    set distance-to-move 0
  ]
end


to choose-new-destination
  let center one-of fire-centers
  set target-center center

  ;; Closest safe gray patch to the fire center
  let target min-one-of patches with [
    pcolor = gray + 2 and not is-fire?
  ] [ distance center ]

  if target != nobody [
    let path a-star-path self target
    ifelse path != [] [
      set destination-path path
      set path-index 0
    ] [
      set destination-path []
      set path-index 0
    ]
  ]
end


to move-responder
  ;; Advance by rescue-speed each tick
  set distance-to-move distance-to-move + rescue-speed

  ;; Continue moving while there's distance left and path remains
  while [is-list? destination-path and path-index < length destination-path and distance-to-move >= 1] [
    let next-patch item path-index destination-path

    ;; Abort if next patch is on fire
    if [is-fire?] of next-patch [
      if mode = "rescue" [ choose-new-destination ]
      stop
    ]

    ;; Move one patch forward
    move-to next-patch
    set path-index path-index + 1
    set distance-to-move distance-to-move - 1

    ;; If reached target patch, pick next goal
    if path-index >= length destination-path and mode = "rescue" [
      choose-new-destination
      stop
    ]
  ]

  ;; If evacuating and reached exit, remove responder
  if is-exit? and mode = "evacuate" [
    die
  ]
end

to perform-rescue
  if mode = "rescue" [
    let nearby-evacuees evacuees in-radius 8
    while [rescue-count < rescue-capacity and any? nearby-evacuees] [
      let target one-of nearby-evacuees
      ask target [ die ]
      set rescue-count rescue-count + 1
      set nearby-evacuees evacuees in-radius 8
    ]

    if rescue-count >= 3 [
      set mode "evacuate"
      let exit one-of patches with [is-exit?]
      let path a-star-path self exit
      ifelse path != [] [
        set destination-path path
        set path-index 0
      ] [
        set destination-path []
        set path-index 0
      ]
    ]
  ]
end



;;;========================
;;; primary cycle
;;;========================

to go
  spread-fire
  if ticks = 0 [ export-view (word "view-tick-0.png") ]
  if ticks = 100 [ export-view (word "view-tick-100.png") ]
  if ticks = 300 [ export-view (word "view-tick-300.png") ]
  if ticks = 500 [ export-view (word "view-tick-500.png") ]
  if ticks = 700 [ export-view (word "view-tick-700.png") ]
  if ticks = 1000 [ export-view (word "view-tick-1000.png") ]
  if ticks = 1200 [ export-view (word "view-tick-1200.png") ]
  if ticks = 1500 [ export-view (word "view-tick-1500.png") ]
  if ticks = 1700 [ export-view (word "view-tick-1700.png") ]
  if ticks = 2000 [ export-view (word "view-tick-2000.png") ]
  ; Continue simulation
  ask evacuees [
    compute-emotion
    update-behavior
    act-based-on-behavior
    ;; Record stuck time if panicking
    if behavior = "panic" [
      set stuck-duration stuck-duration + 1
    ]

    ;; Update emotion-state for tracking
    set emotion-state behavior

  ]
  ask responders [
    perform-rescue
    move-responder
  ]
  tick
end


to move-evacuee
  set distance-to-move distance-to-move + evac-speed

  while [distance-to-move >= 1 and path-index < length evac-path] [
    let next-patch item path-index evac-path

    ;; Exposure check
    if [is-fire?] of next-patch [
      set exposure-flag 1
      set waiting? true
      stop
    ]

    ;; Move one step
    move-to next-patch
    set path-index path-index + 1
    set distance-to-move distance-to-move - 1

    ;; Check for exit
    if is-exit? [
      die
    ]
  ]
end



;;;========================
;;; A* Path search
;;;========================
to-report a-star-path [ src dst ]
  let open-list (list src)
  let closed-list []
  let found? false
  ask src [ set g 0 set h distance dst set f g + h set parent-patch nobody ]
  while [ not found? and not empty? open-list ] [
    set open-list sort-by [[p1 p2] -> ([f] of p1 < [f] of p2)] open-list
    let current first open-list
    set open-list remove-item 0 open-list
    if current = dst [ set found? true ]
    if not found? [
      set closed-list lput current closed-list
      ask current [
        let nbrs sort-on [f] neighbors4
        foreach nbrs [ nbr ->
          if (([travel-cost] of nbr < 999) or [is-fire?] of nbr) and not member? nbr closed-list [
            let tentative-g g + [travel-cost] of nbr
            if not member? nbr open-list [
              ask nbr [ set parent-patch myself set g tentative-g set h distance dst set f g + h ]
              set open-list lput nbr open-list
            ]
            if member? nbr open-list and tentative-g < [g] of nbr [
              ask nbr [ set parent-patch myself set g tentative-g set f g + h ]
            ]
          ]
        ]
      ]
    ]
  ]
  if not found? [ report [] ]
  let path (list dst)
  let node dst
  while [ node != src ] [ set node [parent-patch] of node set path fput node path ]
  set path but-first path
  report path
end



;;;========================
;;; Social Influence Calculator
;;;========================

to compute-social-influence
  set social-influence 0
  let close-turtles evacuees in-radius social-radius with [ self != myself ]
  if any? close-turtles [
    let sum-w 0
    ask close-turtles [
      let d distance myself
      let dist-weight (1 / (1 + d))
      let nb-behavior behavior
      ;; Fetch your own behavior (with reporter blocks)
      let self-behavior [behavior] of myself
      ;; check contagion coefficient in contagion-matrix
      let i position nb-behavior ["calm" "panic" "anxious"]
      let j position self-behavior ["calm" "panic" "anxious"]
      let emo-weight item j (item i contagion-matrix)
      ;; portfolio weighting
      let w dist-weight * emo-weight
      set sum-w sum-w + w
      set social-influence social-influence + (emotion-level * w)
    ]
    if sum-w > 0 [
      set social-influence social-influence / sum-w
    ]
  ]
end



;;;========================
;;; Sentiment calculation: introducing social influence
;;;========================

to compute-emotion
  let exit-p min-one-of patches with [is-exit?] [distance myself]
  let road-p min-one-of patches with [pcolor = gray + 2] [distance myself]
  let fire-p min-one-of patches with [is-fire?] [distance myself]
  let norm-exit 1 - (distance exit-p / 200)
  let norm-road 1 - (distance road-p / 200)
  let norm-fire 1 - (distance fire-p / 200)

  compute-social-influence

  ;; linear combination + tanh activation
  let raw
  ((-0.4  * income-level)
    + (-0.6  * norm-exit)
    + (-0.5  * norm-road)
    + (1   * norm-fire)
    + (0.7   * social-influence))  ;; social-influence adjustable weights
  set emotion-level tanh raw
end

;;;========================
;;; Behavioral decision-making
;;;========================

to update-behavior
  let p emotion-level
  let calm-prob   exp (-3 * p)
  let panic-prob exp (3  * (p - 0.5))
  let anxious-prob  exp (3  * p)
  let total (calm-prob + panic-prob + anxious-prob)

  let calm-p   calm-prob   / total
  let panic-p panic-prob / total
  let anxious-p  anxious-prob  / total

  let r random-float 1
  ifelse r < calm-p [
    set behavior "calm"
  ] [
    ifelse r < (calm-p + panic-p) [
      set behavior "panic"
    ] [
      set behavior "anxious"
    ]
  ]
end

to act-based-on-behavior
  if behavior = "panic" [
    stop
  ]
  if behavior = "calm" [
    if not waiting? [
      move-evacuee
    ]
  ]

  if behavior = "anxious" [
    anxious-move
  ]
end

to anxious-move
  ;; Choose random 4-connected neighbor that is not on fire or blocked
  let choices neighbors4 with [travel-cost < 999 and not is-fire?]

  if any? choices [
    let target one-of choices

    ;; If stepping into fire
    if [is-fire?] of target [
      set exposure-flag 1
      die
    ]

    ;; Move randomly
    move-to target
    set path-index path-index + 1  ;; optional, useful if you still want to count steps
  ]
end




;;;========================
;;; ancillary reporter
;;;========================

to-report tanh [ x ]
  report (exp x - exp (- x)) / (exp x + exp (- x))
end

to-report export-all-indicators
  let low   evacuees with [income-level = 0]
  let mid   evacuees with [income-level = 0.5]
  let high  evacuees with [income-level = 1]

  ;; 1. Panic counts & total counts
  let Nl count low
  let Nm count mid
  let Nh count high

  let Pl count low with [behavior = "panic"]
  let Pm count mid with [behavior = "panic"]
  let Ph count high with [behavior = "panic"]

  ;; 2. Emotional vulnerability index (EVI)
  let EVIl ifelse-value Nl > 0 [ Pl / Nl ] [ 0 ]
  let EVIm ifelse-value Nm > 0 [ Pm / Nm ] [ 0 ]
  let EVIh ifelse-value Nh > 0 [ Ph / Nh ] [ 0 ]

  ;; 3. Mean emotion level
  let meanPl ifelse-value any? low  [ mean [emotion-level] of low  ] [0]
  let meanPm ifelse-value any? mid  [ mean [emotion-level] of mid  ] [0]
  let meanPh ifelse-value any? high [ mean [emotion-level] of high ] [0]

  ;; 4. Mean route-switch count
  let switchl ifelse-value any? low  [ mean [route-switch-count] of low  ] [0]
  let switchm ifelse-value any? mid  [ mean [route-switch-count] of mid  ] [0]
  let switchh ifelse-value any? high [ mean [route-switch-count] of high ] [0]


  ;; 6. Stuck duration
  let stuckl ifelse-value any? low  [ mean [stuck-duration] of low  ] [0]
  let stuckm ifelse-value any? mid  [ mean [stuck-duration] of mid  ] [0]
  let stuckh ifelse-value any? high [ mean [stuck-duration] of high ] [0]

  ;; 7. Exposure rate (ER)
  let expL count low with [exposure-flag = 1]
  let expM count mid with [exposure-flag = 1]
  let expH count high with [exposure-flag = 1]

  let ERl ifelse-value (Nl + expL > 0) [ expL / (Nl + expL) ] [ 0 ]
  let ERm ifelse-value (Nm + expM > 0) [ expM / (Nm + expM) ] [ 0 ]
  let ERh ifelse-value (Nh + expH > 0) [ expH / (Nh + expH) ] [ 0 ]

  ;; 8. Congestion index (CI_t): evacuees per road patch
  let roads patches with [travel-cost = 2]
  let CI ifelse-value any? roads [ count evacuees / count roads ] [0]

  report (list
    meanPl meanPm meanPh     ;; 0–2: mean emotion levels
    EVIl EVIm EVIh           ;; 3–5: EVI (panic rate)
    switchl switchm switchh  ;; 6–8: path changes
    stuckl stuckm stuckh     ;; 9–11: stuck time
    ERl ERm ERh              ;; 12–14: exposure
    CI                       ;; 15: congestion
  )
end
@#$#@#$#@
GRAPHICS-WINDOW
544
13
1454
624
-1
-1
2.0
1
10
1
1
1
0
0
0
1
0
450
0
300
0
0
1
ticks
30.0

BUTTON
51
113
114
146
NIL
setup
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
157
113
220
146
NIL
go
T
1
T
OBSERVER
NIL
NIL
NIL
NIL
0

BUTTON
71
42
203
91
load data
load-data
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

MONITOR
38
358
235
403
emotion
[emotion-level] of tracked-turtle
17
1
11

PLOT
37
428
237
578
Emotion Trace
Time (ticks)
Emotion Value
0.0
0.0
-1.0
1.0
true
false
"clear-all-plots" ""
PENS
"TrackedEmo" 1.0 0 -16777216 true "" "if tracked-turtle != nobody [\n  plotxy ticks [emotion-level] of tracked-turtle\n]\n"

SLIDER
49
168
221
201
low-income-count
low-income-count
0
20
10.0
1
1
NIL
HORIZONTAL

SLIDER
49
231
221
264
mid-income-count
mid-income-count
0
100
50.0
1
1
NIL
HORIZONTAL

SLIDER
50
291
222
324
high-income-count
high-income-count
0
100
50.0
1
1
NIL
HORIZONTAL

SWITCH
323
50
477
83
random-fire?
random-fire?
0
1
-1000

SLIDER
315
106
487
139
fire-speed-kmph
fire-speed-kmph
0
5
2.0
0.1
1
NIL
HORIZONTAL

CHOOSER
312
161
486
206
tracked-income-group
tracked-income-group
"low" "mid" "high"
0

PLOT
300
427
500
577
FirePercent
Time (ticks)
% of Damage
0.0
0.0
0.0
10.0
true
false
"" ""
PENS
"FirePercent" 1.0 0 -2674135 true "" "let burned count patches with [pcolor = red]\nlet total count patches\nplotxy ticks (burned / total * 100)\n"

SLIDER
314
231
486
264
responder-count
responder-count
0
20
5.0
1
1
NIL
HORIZONTAL

SLIDER
314
292
486
325
rescue-capacity
rescue-capacity
0
10
5.0
1
1
NIL
HORIZONTAL

SLIDER
312
362
484
395
random-fire-count
random-fire-count
2
7
3.0
1
1
NIL
HORIZONTAL

MONITOR
337
594
471
639
 Calm Count
count evacuees with [behavior = \"calm\"]
17
1
11

MONITOR
338
655
473
700
Panic Count
count evacuees with [behavior = \"panic\"]
17
1
11

MONITOR
338
714
472
759
Anxious Count
count evacuees with [behavior = \"anxious\"]
17
1
11

PLOT
39
606
239
756
Evacuee Emotion Over Time
Time (ticks)
Number of Evacuees
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"calm" 1.0 0 -13345367 true "" "plot count evacuees with [behavior = \"calm\"]"
"panic" 1.0 0 -16777216 true "" "plot count evacuees with [behavior = \"panic\"]"
"anxious" 1.0 0 -2674135 true "" "plot count evacuees with [behavior = \"anxious\"]"

@#$#@#$#@
## WHAT IS IT?

An ABM on wildfire evacuation.

## HOW IT WORKS

Combined with FCM to simulate the emotion impact.

## HOW TO USE IT

1. Launch NetLogo and load the model from the models/ directory (e.g., WildfireEvacuation.nlogo).
2. Adjust simulation parameters in the interface, such as low-income-count, social-radius, and contagion-rate.
3. Click Setup to initialize the environment, then Go to start the simulation.

## THINGS TO NOTICE

Load data before setup

## THINGS TO TRY

You can adjust parameters in the model to simulate different senarios.

## EXTENDING THE MODEL

Maybe you can try to use a lager study area.
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

airplane
true
0
Polygon -7500403 true true 150 0 135 15 120 60 120 105 15 165 15 195 120 180 135 240 105 270 120 285 150 270 180 285 210 270 165 240 180 180 285 195 285 165 180 105 180 60 165 15

arrow
true
0
Polygon -7500403 true true 150 0 0 150 105 150 105 293 195 293 195 150 300 150

box
false
0
Polygon -7500403 true true 150 285 285 225 285 75 150 135
Polygon -7500403 true true 150 135 15 75 150 15 285 75
Polygon -7500403 true true 15 75 15 225 150 285 150 135
Line -16777216 false 150 285 150 135
Line -16777216 false 150 135 15 75
Line -16777216 false 150 135 285 75

bug
true
0
Circle -7500403 true true 96 182 108
Circle -7500403 true true 110 127 80
Circle -7500403 true true 110 75 80
Line -7500403 true 150 100 80 30
Line -7500403 true 150 100 220 30

butterfly
true
0
Polygon -7500403 true true 150 165 209 199 225 225 225 255 195 270 165 255 150 240
Polygon -7500403 true true 150 165 89 198 75 225 75 255 105 270 135 255 150 240
Polygon -7500403 true true 139 148 100 105 55 90 25 90 10 105 10 135 25 180 40 195 85 194 139 163
Polygon -7500403 true true 162 150 200 105 245 90 275 90 290 105 290 135 275 180 260 195 215 195 162 165
Polygon -16777216 true false 150 255 135 225 120 150 135 120 150 105 165 120 180 150 165 225
Circle -16777216 true false 135 90 30
Line -16777216 false 150 105 195 60
Line -16777216 false 150 105 105 60

car
false
0
Polygon -7500403 true true 300 180 279 164 261 144 240 135 226 132 213 106 203 84 185 63 159 50 135 50 75 60 0 150 0 165 0 225 300 225 300 180
Circle -16777216 true false 180 180 90
Circle -16777216 true false 30 180 90
Polygon -16777216 true false 162 80 132 78 134 135 209 135 194 105 189 96 180 89
Circle -7500403 true true 47 195 58
Circle -7500403 true true 195 195 58

circle
false
0
Circle -7500403 true true 0 0 300

circle 2
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240

cow
false
0
Polygon -7500403 true true 200 193 197 249 179 249 177 196 166 187 140 189 93 191 78 179 72 211 49 209 48 181 37 149 25 120 25 89 45 72 103 84 179 75 198 76 252 64 272 81 293 103 285 121 255 121 242 118 224 167
Polygon -7500403 true true 73 210 86 251 62 249 48 208
Polygon -7500403 true true 25 114 16 195 9 204 23 213 25 200 39 123

cylinder
false
0
Circle -7500403 true true 0 0 300

dot
false
0
Circle -7500403 true true 90 90 120

face happy
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 255 90 239 62 213 47 191 67 179 90 203 109 218 150 225 192 218 210 203 227 181 251 194 236 217 212 240

face neutral
false
0
Circle -7500403 true true 8 7 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Rectangle -16777216 true false 60 195 240 225

face sad
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 168 90 184 62 210 47 232 67 244 90 220 109 205 150 198 192 205 210 220 227 242 251 229 236 206 212 183

fish
false
0
Polygon -1 true false 44 131 21 87 15 86 0 120 15 150 0 180 13 214 20 212 45 166
Polygon -1 true false 135 195 119 235 95 218 76 210 46 204 60 165
Polygon -1 true false 75 45 83 77 71 103 86 114 166 78 135 60
Polygon -7500403 true true 30 136 151 77 226 81 280 119 292 146 292 160 287 170 270 195 195 210 151 212 30 166
Circle -16777216 true false 215 106 30

flag
false
0
Rectangle -7500403 true true 60 15 75 300
Polygon -7500403 true true 90 150 270 90 90 30
Line -7500403 true 75 135 90 135
Line -7500403 true 75 45 90 45

flower
false
0
Polygon -10899396 true false 135 120 165 165 180 210 180 240 150 300 165 300 195 240 195 195 165 135
Circle -7500403 true true 85 132 38
Circle -7500403 true true 130 147 38
Circle -7500403 true true 192 85 38
Circle -7500403 true true 85 40 38
Circle -7500403 true true 177 40 38
Circle -7500403 true true 177 132 38
Circle -7500403 true true 70 85 38
Circle -7500403 true true 130 25 38
Circle -7500403 true true 96 51 108
Circle -16777216 true false 113 68 74
Polygon -10899396 true false 189 233 219 188 249 173 279 188 234 218
Polygon -10899396 true false 180 255 150 210 105 210 75 240 135 240

house
false
0
Rectangle -7500403 true true 45 120 255 285
Rectangle -16777216 true false 120 210 180 285
Polygon -7500403 true true 15 120 150 15 285 120
Line -16777216 false 30 120 270 120

leaf
false
0
Polygon -7500403 true true 150 210 135 195 120 210 60 210 30 195 60 180 60 165 15 135 30 120 15 105 40 104 45 90 60 90 90 105 105 120 120 120 105 60 120 60 135 30 150 15 165 30 180 60 195 60 180 120 195 120 210 105 240 90 255 90 263 104 285 105 270 120 285 135 240 165 240 180 270 195 240 210 180 210 165 195
Polygon -7500403 true true 135 195 135 240 120 255 105 255 105 285 135 285 165 240 165 195

line
true
0
Line -7500403 true 150 0 150 300

line half
true
0
Line -7500403 true 150 0 150 150

pentagon
false
0
Polygon -7500403 true true 150 15 15 120 60 285 240 285 285 120

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

plant
false
0
Rectangle -7500403 true true 135 90 165 300
Polygon -7500403 true true 135 255 90 210 45 195 75 255 135 285
Polygon -7500403 true true 165 255 210 210 255 195 225 255 165 285
Polygon -7500403 true true 135 180 90 135 45 120 75 180 135 210
Polygon -7500403 true true 165 180 165 210 225 180 255 120 210 135
Polygon -7500403 true true 135 105 90 60 45 45 75 105 135 135
Polygon -7500403 true true 165 105 165 135 225 105 255 45 210 60
Polygon -7500403 true true 135 90 120 45 150 15 180 45 165 90

sheep
false
15
Circle -1 true true 203 65 88
Circle -1 true true 70 65 162
Circle -1 true true 150 105 120
Polygon -7500403 true false 218 120 240 165 255 165 278 120
Circle -7500403 true false 214 72 67
Rectangle -1 true true 164 223 179 298
Polygon -1 true true 45 285 30 285 30 240 15 195 45 210
Circle -1 true true 3 83 150
Rectangle -1 true true 65 221 80 296
Polygon -1 true true 195 285 210 285 210 240 240 210 195 210
Polygon -7500403 true false 276 85 285 105 302 99 294 83
Polygon -7500403 true false 219 85 210 105 193 99 201 83

square
false
0
Rectangle -7500403 true true 30 30 270 270

square 2
false
0
Rectangle -7500403 true true 30 30 270 270
Rectangle -16777216 true false 60 60 240 240

star
false
0
Polygon -7500403 true true 151 1 185 108 298 108 207 175 242 282 151 216 59 282 94 175 3 108 116 108

target
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240
Circle -7500403 true true 60 60 180
Circle -16777216 true false 90 90 120
Circle -7500403 true true 120 120 60

tree
false
0
Circle -7500403 true true 118 3 94
Rectangle -6459832 true false 120 195 180 300
Circle -7500403 true true 65 21 108
Circle -7500403 true true 116 41 127
Circle -7500403 true true 45 90 120
Circle -7500403 true true 104 74 152

triangle
false
0
Polygon -7500403 true true 150 30 15 255 285 255

triangle 2
false
0
Polygon -7500403 true true 150 30 15 255 285 255
Polygon -16777216 true false 151 99 225 223 75 224

truck
false
0
Rectangle -7500403 true true 4 45 195 187
Polygon -7500403 true true 296 193 296 150 259 134 244 104 208 104 207 194
Rectangle -1 true false 195 60 195 105
Polygon -16777216 true false 238 112 252 141 219 141 218 112
Circle -16777216 true false 234 174 42
Rectangle -7500403 true true 181 185 214 194
Circle -16777216 true false 144 174 42
Circle -16777216 true false 24 174 42
Circle -7500403 false true 24 174 42
Circle -7500403 false true 144 174 42
Circle -7500403 false true 234 174 42

turtle
true
0
Polygon -10899396 true false 215 204 240 233 246 254 228 266 215 252 193 210
Polygon -10899396 true false 195 90 225 75 245 75 260 89 269 108 261 124 240 105 225 105 210 105
Polygon -10899396 true false 105 90 75 75 55 75 40 89 31 108 39 124 60 105 75 105 90 105
Polygon -10899396 true false 132 85 134 64 107 51 108 17 150 2 192 18 192 52 169 65 172 87
Polygon -10899396 true false 85 204 60 233 54 254 72 266 85 252 107 210
Polygon -7500403 true true 119 75 179 75 209 101 224 135 220 225 175 261 128 261 81 224 74 135 88 99

wheel
false
0
Circle -7500403 true true 3 3 294
Circle -16777216 true false 30 30 240
Line -7500403 true 150 285 150 15
Line -7500403 true 15 150 285 150
Circle -7500403 true true 120 120 60
Line -7500403 true 216 40 79 269
Line -7500403 true 40 84 269 221
Line -7500403 true 40 216 269 79
Line -7500403 true 84 40 221 269

wolf
false
0
Polygon -16777216 true false 253 133 245 131 245 133
Polygon -7500403 true true 2 194 13 197 30 191 38 193 38 205 20 226 20 257 27 265 38 266 40 260 31 253 31 230 60 206 68 198 75 209 66 228 65 243 82 261 84 268 100 267 103 261 77 239 79 231 100 207 98 196 119 201 143 202 160 195 166 210 172 213 173 238 167 251 160 248 154 265 169 264 178 247 186 240 198 260 200 271 217 271 219 262 207 258 195 230 192 198 210 184 227 164 242 144 259 145 284 151 277 141 293 140 299 134 297 127 273 119 270 105
Polygon -7500403 true true -1 195 14 180 36 166 40 153 53 140 82 131 134 133 159 126 188 115 227 108 236 102 238 98 268 86 269 92 281 87 269 103 269 113

x
false
0
Polygon -7500403 true true 270 75 225 30 30 225 75 270
Polygon -7500403 true true 30 75 75 30 270 225 225 270
@#$#@#$#@
NetLogo 6.4.0
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
<experiments>
  <experiment name="IncomeSensitivityTest" repetitions="1" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <timeLimit steps="2000"/>
    <enumeratedValueSet variable="low-income-count">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mid-income-count">
      <value value="50"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="high-income-count">
      <value value="50"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="fire-speed-kmph">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="responder-count">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="rescue-capacity">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="random-fire?">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="random-fire-count">
      <value value="3"/>
    </enumeratedValueSet>
  </experiment>
</experiments>
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
0
@#$#@#$#@
