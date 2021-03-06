module EditorActions
  ( EditorAction(..), Motion(..), Command(..)
  , CursorPos(..), Direction(..), Vertical(..)
  , signal, Key(..), pairs
  ) where

import Keyboard
import Signal exposing ((<~), (~), foldp)
import Char
import Graphics.Element exposing (show, Element)
import String exposing (..)
import Result exposing (Result)
import Debug
import Time exposing (Time, timestamp)
import Set

-- EXTERNAL

type EditorAction = Count Int EditorAction | C Command | M Motion | Noop
type alias TimedAction = (Key, (Time, EditorAction))

type CursorPos = UnderCursor | AfterCursor | BOL | EOL
type Direction = Forward | Backward
type Vertical = Above | Below

type Motion = Up | Down | Left | Right
            | BeginningOfLine { nonBlank : Bool }
            | EndOfLine
            | RepeatFind
            | ReverseFind
            | GotoLine
            | Find {dir : Direction, til : Bool} Char
            | LineUp | LineDown

type Command = EnterInsert CursorPos
             | Delete Motion
             | Remove Direction
             | NewLine Vertical
             | ReplaceChar Char
             | SwapCase
             | Undo | Redo

type Meta = Ctrl
type Key  = Press Char | Esc | Ret | Chord (List Meta) Key


-- INTERNAL

-- represents partially or fully completed key combinations.
-- partial combos carry around a function f which is applied to the resulting
-- EditorAction. We use this to wrap actions in Counts, or to handle
-- commands which operate on motions
type ComboState = Completed EditorAction
                | Partial (EditorAction -> EditorAction) (Key -> ComboState)
                | Null

idPartial : (Key -> ComboState) -> ComboState
idPartial f = Partial identity f

replaceUnderCursor : Key -> ComboState
replaceUnderCursor key = case key of
  Press c -> Completed <| C <| ReplaceChar c
  _     -> Null 

findChar : {dir : Direction, til : Bool} -> Key -> ComboState
findChar params key = case key of
  Press c -> Completed <| M <| Find params c
  _     -> Null

buildCount : String -> Key -> ComboState
buildCount s key = case key of
  Press d -> case (Char.isDigit d) of
    True  -> idPartial <| buildCount (cons d s)
    False -> let
        possibleCount = toInt (reverse s)
      in case possibleCount of
        Err s -> Debug.log s Null
        Ok  n -> case (bindings d) of
          Completed action -> Completed <| Count n action
          Partial f g -> Partial ((Count n) << f) g
          Null -> Null
  _ -> Null

handleKey : Key -> ComboState -> ComboState
handleKey key state = case state of
  Partial f g -> case (g key) of
    Completed action -> Completed <| f action
    _                -> g key
  _         -> case key of
    Esc     -> Completed Noop -- Null?
    Ret     -> Completed <| M Down
    Chord [Ctrl] (Press 'r') -> Completed <| C Redo
    Press c -> case (Char.isDigit c) of
      True  -> case (c == '0') of
        True  -> bindings c
        False -> idPartial <| buildCount (fromChar c)
      False -> bindings c

bindings : Char -> ComboState
bindings c = let
    cc x = Completed (C x)
    cm x = Completed (M x)
  in case c of
    -- commands
    'a' -> cc <| EnterInsert AfterCursor
    'A' -> cc <| EnterInsert EOL
    'i' -> cc <| EnterInsert UnderCursor
    'I' -> cc <| EnterInsert BOL
    'o' -> cc <| NewLine Below
    'O' -> cc <| NewLine Above
    'x' -> cc <| Remove Forward
    'X' -> cc <| Remove Backward
    'r' -> idPartial replaceUnderCursor
    '~' -> cc <| SwapCase
    'u' -> cc <| Undo
    -- motions
    'h' -> cm <| Left
    'j' -> cm <| Down
    'k' -> cm <| Up
    'l' -> cm <| Right
    '0' -> cm <| BeginningOfLine {nonBlank=False}
    '^' -> cm <| BeginningOfLine {nonBlank=True}
    '$' -> cm <| EndOfLine
    ';' -> cm <| RepeatFind
    ',' -> cm <| ReverseFind
    '-' -> cm <| LineUp
    '+' -> cm <| LineDown
    'G' -> cm <| GotoLine
    'f' -> idPartial <| findChar {dir=Forward, til=False}
    'F' -> idPartial <| findChar {dir=Backward, til=False}
    't' -> idPartial <| findChar {dir=Forward, til=True}
    'T' -> idPartial <| findChar {dir=Backward, til=True}
    _   -> Null

comboState : Signal ComboState
comboState = Signal.foldp handleKey Null keys

completedCombo : ComboState -> Maybe EditorAction
completedCombo state = case state of
  Completed act -> Just act
  _             -> Nothing

actions : Signal EditorAction
actions = Signal.filterMap completedCombo Noop comboState

tuples : Signal (Key, (Time, EditorAction))
tuples = (,) <~ keys ~ (timestamp actions)

dedupe : TimedAction -> TimedAction -> TimedAction
dedupe (k1, (t1, a1)) (k2, (t2, a2)) = if (t1 == t2) then (k1, (0, Noop)) else (k1, (t1, a1))

signal : Signal (Key, EditorAction)
signal = (\(a,(b,c)) -> (a,c)) <~ foldp dedupe (Esc, (0, Noop)) tuples

pressChar : Keyboard.KeyCode -> Key
pressChar c = Press (Char.fromCode c)

-- KEY SIGNALS

keys : Signal Key
keys = Signal.mergeMany [ctrlR, esc, ret, pressChar <~ Keyboard.presses]

pairs = (,) <~ Keyboard.presses ~ metasDown

ctrlR' : Signal Key
ctrlR' = let
    pairs = (,) <~ Keyboard.presses ~ metasDown
    mapFn (kc, metas) = case (List.member Ctrl metas) of
      False -> Nothing
      True  -> case (Char.fromCode kc == 'r') of
        False -> Nothing
        True  -> Just <| Chord [Ctrl] <| Press 'r'
  in Signal.filterMap mapFn Esc pairs

ctrlR : Signal Key
ctrlR = let
    fn set = case (17 `Set.member` set && 82 `Set.member` set) of
      True -> Just <| Chord [Ctrl] <| Press 'r'
      False -> Nothing
  in Signal.filterMap fn Esc Keyboard.keysDown

metasDown : Signal (List Meta)
metasDown = let
    fn set = case (Set.member 17 set) of
      True  -> Just [Ctrl]
      False -> Nothing
  in Signal.filterMap fn [] Keyboard.keysDown

ret : Signal Key
ret = Signal.sampleOn Keyboard.enter (Signal.constant Ret) 

esc : Signal Key
esc = let
    escDown = Signal.filter identity False <| Keyboard.isDown 27
  in Signal.sampleOn escDown (Signal.constant Esc)