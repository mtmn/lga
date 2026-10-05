# HPP lattice gas automaton, rendered to mp4 with ffmpeg
#
# The Hardy, Pomeau and de Pazzis model (1973, 1976) uses a square lattice
# with 4 velocities. Each cell holds up to 4 particles, one per direction:
# E=1 N=2 W=4 S=8.
# Each step updates all cells at once:
#   1. collide: head-on pairs turn 90 degrees, so 5 (E+W) becomes
#      10 (N+S) and back. All other states pass through unchanged.
#      Mass and momentum are conserved.
#   2. stream: each particle moves one cell along its direction.
#      Solid cells bounce particles back, direction reversed.
# Sources: Wikipedia pages "Lattice gas automaton" and "HPP model";
# Frisch, Hasslacher and Pomeau, 1986 (the hexagonal FHP variant,
# which restores isotropy).
#
(def options
  [[:frames 600 :int "frames to render"]
   [:width 1000 :int "simulation width in cells"]
   [:height 1000 :int "simulation height in cells"]
   [:scale 2 :int "output pixels per cell"]
   [:fps 30 :int "output frame rate"]
   [:steps 2 :int "automaton steps per frame"]
   [:gas 0.12 :number "background particle density, 0 to 1"]
   [:burst 0.75 :number "dense square particle density, 0 to 1"]
   [:seed nil :int "random seed (default: current time)"]
   [:crf 23 :int "x264 quality, lower is better"]
   [:preset "veryfast" :string "x264 speed preset"]])

(def default-out "lga-2000.mp4")

(def wall
  "Wall thickness in cells, thick enough that streaming never leaves the grid."
  2)

(def shade
  "Gray level for each cell state, by particle count."
  (seq [s :range [0 16]]
    (min 255 (* 64 (count |(not= 0 (band s $)) [1 2 4 8])))))

(def gray-strings
  "One rgb24 byte triple per gray level, for buffer/push-string."
  (seq [g :in shade] (string/from-bytes g g g)))

# command line

(defn usage [code]
  (def out (if (= code 0) stdout stderr))
  (xprint out "usage: janet lga.janet [options] [out.mp4]\n")
  (xprintf out "  %-28s output file [%s]" "out.mp4" default-out)
  (each [name dflt kind help] options
    (xprintf out "  %-28s %s%s"
             (if (= kind :bool) (string "--[no-]" name) (string "--" name " " kind))
             help
             (if (nil? dflt) "" (string " [" dflt "]"))))
  (xprintf out "  %-28s show this help" "-h, --help")
  (os/exit code))

(defn fail [& msg]
  (eprint "lga: " ;msg)
  (eprint "try: janet lga.janet --help")
  (os/exit 2))

(defn parse-value [name kind s]
  (when (nil? s) (fail "--" name " needs a value"))
  (if (= kind :string)
    s
    (let [n (scan-number s)]
      (if ((if (= kind :int) int? number?) n)
        n
        (fail "--" name " must be " (if (= kind :int) "an integer" "a number")
              ", got " s)))))

(defn validate [cfg]
  (each name [:frames :width :height :scale :fps :steps]
    (def v (cfg name))
    (when (and v (< v 1)) (fail "--" name " must be at least 1")))
  (each name [:gas :burst]
    (unless (<= 0 (cfg name) 1) (fail "--" name " must be between 0 and 1")))
  (def {:width w :height h :scale scale} cfg)
  (when (or (<= w (* 2 wall)) (<= h (* 2 wall)))
    (fail "grid must be larger than " (* 2 wall) "x" (* 2 wall)))
  # libx264 with yuv420p needs even frame dimensions
  (when (or (odd? (* w scale)) (odd? (* h scale)))
    (fail "output size " (* w scale) "x" (* h scale)
          " must be even, change --width, --height or --scale"))
  cfg)

(defn parse-args [args]
  (def kinds (tabseq [[name _ kind] :in options] name kind))
  (def cfg (tabseq [[name dflt] :in options] name dflt))
  (put cfg :out default-out)
  (var i 0)
  (while (< i (length args))
    (def arg (args i))
    (++ i)
    (cond
      (index-of arg ["-h" "--help"]) (usage 0)
      (not (string/has-prefix? "-" arg)) (put cfg :out arg)
      (not (string/has-prefix? "--" arg)) (fail "unknown option " arg)
      (let [negated (string/has-prefix? "--no-" arg)
            name (keyword (string/slice arg (if negated 5 2)))
            kind (kinds name)]
        (cond
          (or (nil? kind) (and negated (not= kind :bool)))
          (fail "unknown option " arg)
          (= kind :bool) (put cfg name (not negated))
          (do
            (put cfg name (parse-value name kind (get args i)))
            (++ i))))))
  (validate cfg))

# world

(defn on-grid
  "Scale a length given for a 250 cell grid to `size` cells."
  [v size]
  (math/round (/ (* v size) 250)))

(defn add-walls [solid w h]
  (loop [y :range [0 h] x :range [0 w]
         :when (or (< x wall) (>= x (- w wall)) (< y wall) (>= y (- h wall)))]
    (put solid (+ x (* y w)) 1)))

(defn fill-gas
  "Fill cells at random: thin background gas plus a dense square left of
  center that runs right as a wave. The square is 64 cells at x 20, y 92
  on a 250 grid, scaled for other grid sizes."
  [solid w h gas burst]
  (def x0 (on-grid 20 w))
  (def x1 (+ x0 (on-grid 64 w)))
  (def y0 (on-grid 92 h))
  (def y1 (+ y0 (on-grid 64 h)))
  (def cells (buffer/new-filled (* w h) 0))
  (loop [y :range [0 h] x :range [0 w]
         :let [i (+ x (* y w))]
         :when (= 0 (get solid i))
         :let [p (if (and (<= x0 x) (< x x1) (<= y0 y) (< y y1)) burst gas)]]
    (put cells i (reduce |(if (< (math/random) p) (bor $0 $1) $0) 0 [1 2 4 8])))
  cells)

# simulation

(defmacro- stream
  "Move particle `bit` from cell i to j, or bounce it back as `back` off a solid."
  [nxt solid c i j bit back]
  ~(when (not= 0 (band ,c ,bit))
     (if (= 0 (get ,solid ,j))
       (put ,nxt ,j (bor (get ,nxt ,j) ,bit))
       (put ,nxt ,i (bor (get ,nxt ,i) ,back)))))

(defn step
  "Collide and stream every cell of `cur` into `nxt`."
  [cur nxt solid w h]
  (buffer/fill nxt 0)
  (loop [y :range [wall (- h wall)] x :range [wall (- w wall)]
         :let [i (+ x (* y w))
               st (get cur i)]
         :when (not= st 0)
         :let [c (case st 5 10 10 5 st)]]
    (stream nxt solid c i (+ i 1) 1 4)
    (stream nxt solid c i (- i w) 2 8)
    (stream nxt solid c i (- i 1) 4 1)
    (stream nxt solid c i (+ i w) 8 2)))

(defn render
  "Write `cur` as rgb24 into `frame`: one gray level per particle count."
  [frame cur]
  (buffer/clear frame)
  (loop [i :range [0 (length cur)]]
    (buffer/push-string frame (get gray-strings (get cur i)))))

(defn spawn-ffmpeg [{:width w :height h :scale scale :fps fps
                     :crf crf :preset preset :out out}]
  (os/spawn ["ffmpeg" "-y" "-v" "warning"
             "-f" "rawvideo" "-pix_fmt" "rgb24"
             "-s" (string w "x" h) "-r" (string fps)
             "-i" "-"
             "-vf" (string "scale=" (* w scale) "x" (* h scale) ":flags=neighbor")
             "-c:v" "libx264" "-pix_fmt" "yuv420p"
             "-crf" (string crf) "-preset" preset
             "-movflags" "+faststart" out]
            :p {:in :pipe}))

(defn main [_ & args]
  (def cfg (parse-args args))
  (def {:width w :height h :scale scale :frames frames :out out} cfg)
  (def n (* w h))
  (def solid (buffer/new-filled n 0))
  (add-walls solid w h)
  (def seed (or (cfg :seed) (os/time)))
  (math/seedrandom seed)
  (var cur (fill-gas solid w h (cfg :gas) (cfg :burst)))
  (var nxt (buffer/new-filled n 0))
  (def frame (buffer/new (* n 3)))

  (print "HPP lattice gas " w "x" h " -> " (* w scale) "x" (* h scale) " " out)
  (print "frames " frames " fps " (cfg :fps) " steps-per-frame " (cfg :steps)
         " seed " seed)
  (def ffmpeg (spawn-ffmpeg cfg))
  (def t0 (os/clock :monotonic))
  (defn elapsed [] (- (os/clock :monotonic) t0))
  (for f 1 (inc frames)
    (repeat (cfg :steps)
      (step cur nxt solid w h)
      (def tmp cur)
      (set cur nxt)
      (set nxt tmp))
    (render frame cur)
    (:write (ffmpeg :in) frame)
    (when (= 0 (% f 60))
      (printf "frame %d/%d fps %.1f" f frames (/ f (max (elapsed) 1e-9)))))

  (:close (ffmpeg :in))
  (def code (os/proc-wait ffmpeg))
  (printf "ffmpeg exit %d in %.1fs -> %s" code (elapsed) out)
  (unless (= code 0) (os/exit code)))
