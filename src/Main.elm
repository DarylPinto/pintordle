port module Main exposing (LetterPosition(..), rowFromGuess)

import Array
import Basics exposing (..)
import Browser
import Browser.Events
import Common exposing (isPintoWord)
import Dictionary exposing (answers, guessableWords)
import Html exposing (..)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)
import Json.Decode as Decode
import Process
import Set
import Task
import Time


turnLimit : Int
turnLimit =
    6


maxWordLength : Int
maxWordLength =
    5


alphabet : List Char
alphabet =
    "abcdefghijklmnopqrstuvwxyz" |> String.toList


defaultWord : String
defaultWord =
    "hello"



-- Extra list functions


{-| Get the first element that satisfies the test
-}
listFind : (a -> Bool) -> List a -> Maybe a
listFind isGood xs =
    xs |> List.filter isGood |> List.head


{-| Get all elements in a list except for the last
-}
listInit : List a -> Maybe (List a)
listInit xs =
    case xs of
        [] ->
            Nothing

        _ ->
            Just (xs |> List.take (List.length xs - 1))


{-| Combine two lists into a single list of tuples
-}
listZip : List a -> List b -> List ( a, b )
listZip xs ys =
    List.map2 Tuple.pair xs ys


{-| Create a new list with no duplicates
-}
listUnique : List comparable -> List comparable
listUnique xs =
    xs |> Set.fromList |> Set.toList


{-| Remove the first occurence of item from list
-}
listRemove : a -> List a -> List a
listRemove item items =
    case items of
        [] ->
            []

        x :: xs ->
            if item == x then
                xs

            else
                x :: listRemove item xs



-- Utility functions


{-| Credit to @genderquery for this algorithm,
I wasn't able to figure out how to do this elegantly after hours of trying
-}
generateTileList : List ( Char, Char ) -> List Char -> List Tile
generateTileList pairs word =
    case pairs of
        [] ->
            []

        ( guessLetter, wordLetter ) :: xs ->
            if guessLetter == wordLetter then
                ( guessLetter, Correct ) :: generateTileList xs word

            else if List.member guessLetter word then
                ( guessLetter, Present ) :: generateTileList xs (listRemove guessLetter word)

            else
                ( guessLetter, Absent ) :: generateTileList xs word


{-| Given a word and a guess, output a row of tiles representing the guess's accuracy
-}
rowFromGuess : List Char -> List Char -> Row
rowFromGuess word guess =
    let
        missingLetterLength : Int
        missingLetterLength =
            maxWordLength - List.length guess

        emptyTiles : List Tile
        emptyTiles =
            List.repeat missingLetterLength ( ' ', Absent )

        pairs : List ( Char, Char )
        pairs =
            listZip guess word

        incorrectLetters : List Char
        incorrectLetters =
            pairs
                |> List.filterMap
                    (\( guessLetter, wordLetter ) ->
                        if guessLetter == wordLetter then
                            Nothing

                        else
                            Just wordLetter
                    )

        tileList : List Tile
        tileList =
            generateTileList pairs incorrectLetters
    in
    List.append tileList emptyTiles


{-| Convert the entire board into a single list of unique tiles
-}
toUniqueTiles : Board -> List Tile
toUniqueTiles board =
    let
        letterPositionToInt : LetterPosition -> Int
        letterPositionToInt pos =
            case pos of
                Correct ->
                    1

                Present ->
                    2

                Absent ->
                    3

                Unknown ->
                    4

        intToLetterPosition : Int -> LetterPosition
        intToLetterPosition int =
            case int of
                1 ->
                    Correct

                2 ->
                    Present

                3 ->
                    Absent

                _ ->
                    Unknown
    in
    board
        |> List.concat
        |> List.map (\( char, pos ) -> ( char, letterPositionToInt pos ))
        |> listUnique
        |> List.map (\( char, int ) -> ( char, intToLetterPosition int ))


{-| Serialize `LetterPosition` type into a string
-}
letterPosToString : LetterPosition -> String
letterPosToString pos =
    case pos of
        Correct ->
            "correct"

        Present ->
            "present"

        Absent ->
            "absent"

        Unknown ->
            ""


{-| Parse a string into a `LetterPosition`
-}
stringToLetterPos : String -> LetterPosition
stringToLetterPos pos =
    case pos of
        "correct" ->
            Correct

        "present" ->
            Present

        "absent" ->
            Absent

        _ ->
            Unknown


{-| Converts data coming from the javascript side via ports into a `Board` and
`GameState` that we can use in our model
-}
parseJsSaveData : JsSaveData -> ( Board, GameState )
parseJsSaveData ( jsBoard, jsGameState ) =
    let
        jsTileToTile : ( String, String ) -> Tile
        jsTileToTile tile =
            ( tile
                |> Tuple.first
                |> String.uncons
                |> Maybe.map Tuple.first
                |> Maybe.withDefault 'a'
            , tile
                |> Tuple.second
                |> stringToLetterPos
            )

        board =
            jsBoard |> List.map (\row -> row |> List.map jsTileToTile)

        gameState =
            case jsGameState of
                "win" ->
                    Win

                "loss" ->
                    Loss

                _ ->
                    Playing
    in
    ( board, gameState )


{-| Converts data from our model (namely the `Board` and `GameState`) into a format
that we can transfer over to the javascript side via ports
-}
toJsSaveData : ( Board, GameState ) -> JsSaveData
toJsSaveData ( board, gameState ) =
    let
        toJsTile : Tile -> ( String, String )
        toJsTile tile =
            ( tile
                |> Tuple.first
                |> String.fromChar
            , tile
                |> Tuple.second
                |> letterPosToString
            )

        jsBoard =
            board |> List.map (\row -> row |> List.map toJsTile)

        jsGameState =
            case gameState of
                Win ->
                    "win"

                Loss ->
                    "loss"

                Playing ->
                    "playing"
    in
    ( jsBoard, jsGameState )


{-| Used for conditional rendering
-}
htmlIf : Bool -> Html Msg -> Html Msg
htmlIf condition html =
    if condition then
        html

    else
        text ""



---- PORTS ----


port copyResultsToClipboard : ( List (List String), Bool ) -> Cmd msg


port save : JsSaveData -> Cmd msg


port load : (JsSaveData -> msg) -> Sub msg



---- SUBSCRIPTIONS ----


{-| Keyboard event listener
<https://stackoverflow.com/a/53800798/7003127>
-}
subscriptions : Model -> Sub Msg
subscriptions _ =
    let
        toKey : String -> Msg
        toKey string =
            let
                isKeyInAplhabet : Bool
                isKeyInAplhabet =
                    List.member string (alphabet |> List.map String.fromChar)
            in
            case string of
                "Enter" ->
                    Submit

                "Backspace" ->
                    Backspace

                _ ->
                    if isKeyInAplhabet then
                        case string |> String.toList |> List.head of
                            Just char ->
                                Guess char

                            Nothing ->
                                NoOp

                    else
                        NoOp

        keyDecoder : Decode.Decoder Msg
        keyDecoder =
            Decode.map toKey (Decode.field "key" Decode.string)
    in
    Sub.batch
        [ Browser.Events.onKeyDown keyDecoder
        , load LoadSaveData
        ]



---- TYPES ----


type LetterPosition
    = Correct
    | Present
    | Absent
    | Unknown


type alias Tile =
    ( Char, LetterPosition )


type alias Row =
    List Tile


type alias Board =
    List Row


type GameState
    = Win
    | Loss
    | Playing


type alias JsBoard =
    List (List ( String, String ))


type alias JsGameState =
    String


type alias JsSaveData =
    ( JsBoard, JsGameState )



---- MODEL ----


type alias Model =
    { word : List Char
    , board : Board
    , inputBuffer : List Char
    , gameState : GameState
    , toastMessages : List String
    }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { word = defaultWord |> String.toList
      , board = []
      , inputBuffer = []
      , gameState = Playing
      , toastMessages = []
      }
    , Task.perform SetWord Time.now
    )



---- UPDATE ----


type Msg
    = NoOp
    | SetWord Time.Posix
    | LoadSaveData JsSaveData
    | Guess Char
    | Backspace
    | Submit
    | ShowToast Float String
    | HideToast
    | Share


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        isFinalTurn =
            List.length model.board == turnLimit - 1

        isMaxTurnCountReached =
            List.length model.board >= turnLimit

        isInputBufferFull =
            List.length model.inputBuffer == maxWordLength
    in
    case msg of
        NoOp ->
            ( model, Cmd.none )

        SetWord time ->
            let
                -- answer will be different each day
                daysSinceEpoch : Int
                daysSinceEpoch =
                    (time |> Time.posixToMillis) // 1000 // 60 // 60 // 24

                answerIndex : Int
                answerIndex =
                    Basics.modBy (Array.length answers) daysSinceEpoch
            in
            ( { model
                | word =
                    answers
                        |> Array.get answerIndex
                        |> Maybe.withDefault defaultWord
                        |> String.toList
              }
            , Cmd.none
            )

        LoadSaveData data ->
            let
                ( newBoard, newGameState ) =
                    parseJsSaveData data
            in
            ( { model | board = newBoard, gameState = newGameState }
            , Cmd.none
            )

        Guess letter ->
            case model.gameState of
                Playing ->
                    if not isInputBufferFull && not isMaxTurnCountReached then
                        ( { model | inputBuffer = List.append model.inputBuffer [ letter ] }
                        , Cmd.none
                        )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        Backspace ->
            ( { model
                | inputBuffer =
                    model.inputBuffer
                        |> listInit
                        |> Maybe.withDefault []
                , toastMessages =
                    if model.gameState == Playing then
                        []

                    else
                        model.toastMessages
              }
            , Cmd.none
            )

        ShowToast millis message ->
            ( { model | toastMessages = model.toastMessages |> List.append [ message ] }
            , Task.perform (\_ -> HideToast) (Process.sleep millis)
            )

        HideToast ->
            ( { model
                | toastMessages =
                    model.toastMessages
                        |> listInit
                        |> Maybe.withDefault []
              }
            , Cmd.none
            )

        Submit ->
            let
                inputWord =
                    String.fromList model.inputBuffer

                newRow =
                    rowFromGuess model.word model.inputBuffer

                newGameState =
                    if model.inputBuffer == model.word then
                        Win

                    else if isFinalTurn then
                        Loss

                    else
                        Playing

                isInputBufferAGuessableWord =
                    List.member inputWord guessableWords

                isInputAPintoWord =
                    isPintoWord inputWord
            in
            if model.gameState == Playing && not isInputBufferFull then
                update (ShowToast 1250 "Not enough letters") model

            else if inputWord == "pinto" then
                update (ShowToast 2250 "That would be too easy, wouldn't it?") model

            else if isInputBufferFull then
                if not isInputBufferAGuessableWord then
                    update (ShowToast 1250 "Not in word list") model

                else if not isInputAPintoWord then
                    update (ShowToast 3000 "Word does not have any letters in the same position as \"PINTO\"") model

                else if not isMaxTurnCountReached then
                    let
                        newBoard =
                            List.append model.board [ newRow ]
                    in
                    ( { model
                        | board = newBoard
                        , inputBuffer = []
                        , gameState = newGameState
                      }
                    , save <| toJsSaveData ( newBoard, newGameState )
                    )

                else
                    ( model, Cmd.none )

            else
                ( model, Cmd.none )

        -- written like trash but it's 4am and i need to get this done asap
        Share ->
            ( update (ShowToast 1250 "Copied results to clipboard") model |> Tuple.first
            , Cmd.batch
                [ copyResultsToClipboard
                    ( model.board
                        |> List.map
                            (\row ->
                                row
                                    |> List.map
                                        (\( _, color ) ->
                                            case color of
                                                Correct ->
                                                    "🟩"

                                                Present ->
                                                    "🟨"

                                                _ ->
                                                    "⬛"
                                        )
                            )
                    , model.gameState
                        == Win
                    )
                , Task.perform (\_ -> HideToast) (Process.sleep 3000)
                ]
            )



---- VIEW ----


view : Model -> Html Msg
view model =
    let
        -- List of 'letter' buttons to guess with
        buttonList : String -> List (Html Msg)
        buttonList str =
            let
                uniqueTiles =
                    model.board |> toUniqueTiles
            in
            str
                |> String.toList
                |> List.map
                    (\letter ->
                        let
                            tileForThisLetter =
                                uniqueTiles
                                    |> listFind (\t -> (t |> Tuple.first) == letter)

                            tileClassName =
                                case tileForThisLetter of
                                    Just tile ->
                                        tile |> Tuple.second |> letterPosToString

                                    Nothing ->
                                        ""
                        in
                        button
                            [ onClick (Guess letter), class tileClassName ]
                            [ text (String.fromChar letter) ]
                    )

        -- Submitted guesses represented as rows of tiles
        rowToHtml : Row -> Html Msg
        rowToHtml row =
            div [ class "row" ]
                (row
                    |> List.map
                        (\tile ->
                            let
                                className : String
                                className =
                                    if (tile |> Tuple.first) == ' ' then
                                        "tile empty "

                                    else
                                        "tile not-empty "
                            in
                            div
                                [ class
                                    (tile
                                        |> Tuple.second
                                        |> letterPosToString
                                        |> String.append className
                                    )
                                ]
                                [ text (tile |> Tuple.first |> String.fromChar) ]
                        )
                )

        remainingTurnCount : Int
        remainingTurnCount =
            turnLimit - List.length model.board

        -- Current guess represented as a row of tiles
        inputBufferTileRow : Html Msg
        inputBufferTileRow =
            rowFromGuess (List.repeat maxWordLength ' ') model.inputBuffer
                |> List.map (\t -> ( Tuple.first t, Unknown ))
                |> rowToHtml
                |> htmlIf (remainingTurnCount > 0)

        -- Rows of empty tiles representing remaining turns
        remainingRows : List (Html Msg)
        remainingRows =
            div [ class "row" ] (List.repeat maxWordLength (div [ class "tile empty" ] []))
                |> List.repeat (remainingTurnCount - 1)

        gameStateText : Html Msg
        gameStateText =
            case model.gameState of
                Win ->
                    button [ onClick Share, class "share" ] [ text "Share" ]

                Loss ->
                    div []
                        [ h2 [] [ text "Maybe next time" ]
                        , p [ class "loss-text" ] [ text ("The word was \"" ++ String.fromList model.word ++ "\"") ]
                        ]

                _ ->
                    text ""

        toastList : List (Html Msg)
        toastList =
            model.toastMessages
                |> List.map
                    (\message ->
                        div [ class "toast" ] [ text message ]
                    )
    in
    div [ class "game" ]
        [ header [] [ h1 [] [ text "Pintordle" ] ]
        , div [ class "board" ]
            (List.concat
                [ List.map rowToHtml model.board
                , [ inputBufferTileRow ]
                , remainingRows
                ]
            )
        , htmlIf (model.gameState /= Playing) gameStateText
        , div [ class "keyboard" ]
            [ div [] (buttonList "qwertyuiop")
            , div [] (buttonList "asdfghjkl")
            , div []
                (List.concat
                    [ [ button [ onClick Submit, class "enter" ] [ text "Enter" ] ]
                    , buttonList "zxcvbnm"
                    , [ button [ onClick Backspace, class "backspace" ] [ text "⌫" ] ]
                    ]
                )
            ]
        , div [ class "toast-container" ] toastList
        ]



---- PROGRAM ----


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
