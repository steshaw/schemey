module Main where

import System.Environment (getArgs)
import System.IO (isEOF, hFlush, stdout, Handle)
import Text.ParserCombinators.Parsec hiding (spaces)
import Data.List (foldl1', genericLength)
import Numeric (readOct, readDec, readHex)
import Data.Char (toUpper, toLower)
import Data.Maybe (isNothing)
import Control.Exception (AsyncException(..), catch, throw)
import Control.Monad.Except (throwError)
import Control.Monad.Trans.Either
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Control.Monad.Trans (liftIO)
import Control.Monad (unless)
import Control.Concurrent (threadDelay)

-- =============================================================================
-- AST
-- =============================================================================

data Err
  = NumArgs Integer [Val]
  | TypeMismatch String Val
  | Parser ParseError
  | BadSpecialForm String Val
  | NotFunction String Val
  | UnboundVar String String
  | Default String

showErr :: Err -> String
showErr (UnboundVar msg var) = msg ++ ": " ++ var
showErr (BadSpecialForm msg form) = msg ++ ": " ++ show form
showErr (NotFunction msg proc) = msg ++ ": " ++ show proc
showErr (NumArgs expected found) =
  "Expected " ++ show expected ++
  " args; found values " ++ unwordsList found
showErr (TypeMismatch expected found) =
  "Invalid type: expected " ++ expected ++
  ", found " ++ show found
showErr (Parser parseErr) = "Parse error at " ++ show parseErr
showErr (Default s) = "Error: " ++ s

instance Show Err where show = showErr

type ThrowError = EitherT Err IO

type PrimF = [Val] -> ThrowError Val

data Val
  = Symbol String
  | List [Val]
  | DottedList [Val] Val
  | Number Integer
  | Float Float
  | Char Char
  | String String
  | Boolean Bool
  | Port Handle
  | PrimitiveFunc PrimF
  | Func
      { funcParams :: [String]
      , funcVarArg :: Maybe String
      , funcBody   :: [Val]
      , funcEnv    :: Env
      }

-- =============================================================================
-- Parser
-- =============================================================================

dq :: Char
dq = '"'

caseInsensitiveChar :: Char -> Parser Char
caseInsensitiveChar c = char (toLower c) <|> char (toUpper c)

caseInsensitiveString :: String -> Parser String
caseInsensitiveString s = try (mapM caseInsensitiveChar s) <?> show s

parseChar :: Parser Val
parseChar = try $ do
  _ <- char '#' >> char '\\'
  named "space" ' '
    <|> named "newline" '\n'
    <|> otherChar
  where
    named :: String -> Char -> Parser Val
    named s c = caseInsensitiveString s >> return (Char c)
    otherChar :: Parser Val
    otherChar = anyChar >>= \c -> return $ Char c

parseString :: Parser Val
parseString = do
  _ <- char dq
  x <- many ((char '\\' >> escapes) <|> noneOf [dq])
  _ <- char dq
  return $ String x
    where
      escapes = dq <$ char dq
            <|> '\n' <$ char 'n'
            <|> '\r' <$ char 'r'
            <|> '\t' <$ char 't'
            <|> '\\' <$ char '\\'

parseSymbol :: Parser Val
parseSymbol = do
  first <- letter <|> symbol
  rest <- many (letter <|> digit <|> symbol)
  let s = first:rest
  return $ case s of
    "#t" -> Boolean True
    "#f" -> Boolean False
    _    -> Symbol s

radix :: Char -> String -> (String -> Integer) -> Parser Integer
radix c validDigits convert = try $ do
  _ <- char '#' >> char c
  ds <- many1 (oneOf validDigits)
  return $ convert ds

number :: Parser Integer
number = do
  ds <- many1 digit
  return $ read ds

float :: Parser Float
float = try $ do
  as <- many1 digit
  _ <- char '.'
  bs <- many1 digit
  return $ read (as ++ "." ++ bs)

extractNum :: [(t, String)] -> t
extractNum [(num, "")] = num
extractNum _           = error "invalid number"

parseNumber :: Parser Val
parseNumber = (
      radix 'b' ['0'..'1'] error -- FIX
  <|> radix 'o' ['0'..'7'] (extractNum . readOct)
  <|> radix 'd' ['0'..'9'] (extractNum . readDec)
  <|> radix 'x' (['0'..'9'] ++ ['A'..'F']) (extractNum . readHex)
  <|> number
  ) ===> Number
    where
      (===>) = flip fmap

parseList :: Parser Val
parseList = List <$> sepBy parseExpr spaces

parseDottedList :: Parser Val
parseDottedList = do
  hd <- endBy parseExpr spaces
  tl <- char '.' >> spaces >> parseExpr
  return $ DottedList hd tl

parseQuoted :: Parser Val
parseQuoted = do
  _ <- char '\''
  x <- parseExpr
  return $ List [Symbol "quote", x]

parseExpr :: Parser Val
parseExpr =
      fmap Float float
  <|> parseNumber
  <|> parseChar
  <|> parseString
  <|> parseSymbol
  <|> parseQuoted
  <|> do _ <- char '('
         l <- try parseList <|> parseDottedList
         _ <- char ')'
         return l

symbol :: Parser Char
symbol = oneOf "!#$%&|*+-/:<=>?@^_~"

spaces :: Parser ()
spaces = skipMany1 space

-- =============================================================================
-- Evaluator
-- =============================================================================

type Env = IORef [(String, IORef Val)]

newEnv :: IO Env
newEnv = newIORef []

isBound :: Env -> String -> ThrowError Bool
isBound envRef var = do
  env <- liftIO $ readIORef envRef
  case lookup var env of
    Nothing -> return False
    Just _  -> return True

getVar :: Env -> String -> ThrowError Val
getVar envRef var = do
  env <- liftIO $ readIORef envRef
  case lookup var env of
    Nothing -> throwError $ UnboundVar "Getting an unbound variable" var
    Just v  -> liftIO $ readIORef v

setVar :: Env -> String -> Val -> ThrowError Val
setVar envRef var val = do
  env <- liftIO $ readIORef envRef
  case lookup var env of
    Nothing      -> throwError $ UnboundVar "Setting an unbound variable" var
    Just valRef  -> liftIO $ writeIORef valRef val
  return val

newBinding :: String -> Val -> IO (String, IORef Val)
newBinding var val = do
  valRef <- newIORef val
  return (var, valRef)

createVar :: Env -> String -> Val -> ThrowError Val
createVar envRef var val = liftIO $ do
  env <- readIORef envRef
  binding <- newBinding var val
  writeIORef envRef (binding : env)
  return val

defineVar :: Env -> String -> Val -> ThrowError Val
defineVar envRef var val = do
  alreadyDefined <- isBound envRef var
  if alreadyDefined
     then setVar envRef var val
     else createVar envRef var val

bindVars :: Env -> [(String, Val)] -> IO Env
bindVars envRef bindings = do
  env <- readIORef envRef
  env' <- (++ env) <$> mapM (uncurry newBinding) bindings
  newIORef env'

-- FIX: (map showVal params)? Instead check they are symbols
makeFunc :: Maybe String -> Env -> [Val] -> PrimF
makeFunc varArg_ env params_ body_ = return $ Func (map showVal params_) varArg_ body_ env

makeNormalFunc :: Env -> [Val] -> PrimF
makeNormalFunc = makeFunc Nothing

-- FIX: remove showVal hack
makeVarArgsFunc :: Val -> Env -> [Val] -> PrimF
makeVarArgsFunc varArg_ = makeFunc (Just (showVal varArg_))

eval :: Env -> Val -> ThrowError Val
eval _ val@(String _)               = return val
eval _ val@(Number _)               = return val
eval _ val@(Float _)                = return val
eval _ val@(Char _)                 = return val
eval _ val@(Boolean _)              = return val
eval env (Symbol var)               = getVar env var
eval env (List [Symbol "if", t, whenTrue, whenFalse]) = do
  result <- eval env t
  case result of
    Boolean True -> eval env whenTrue
    _            -> eval env whenFalse
eval env (List [Symbol "load", String fileName]) = do
  exprs <- readExprsFile fileName
  vals <- mapM (eval env) exprs
  return $ last vals
eval _ (List [Symbol "quote", val]) = return val
eval env (List [Symbol "set!", Symbol var, expr]) = do
  val <- eval env expr
  setVar env var val
eval env (List [Symbol "define", Symbol var, expr]) = do
  val <- eval env expr
  defineVar env var val

eval env (List (Symbol "define" : List (Symbol sym : params_) : body_)) =
 makeNormalFunc env params_ body_ >>= defineVar env sym
eval env (List (Symbol "define" : DottedList (Symbol sym : params_) varargs : body_)) =
 makeVarArgsFunc varargs env params_ body_ >>= defineVar env sym

eval env (List (Symbol "lambda" : List params_ : body_)) =
 makeNormalFunc env params_ body_
eval env (List (Symbol "lambda" : DottedList params_ varargs : body_)) =
 makeVarArgsFunc varargs env params_ body_
eval env (List (Symbol "lambda" : vararg : body_)) =
 makeVarArgsFunc vararg env [] body_

eval env (List (f : args)) = do
  ef <- eval env f
  eArgs <- mapM (eval env) args
  apply ef eArgs
-- TODO: eval DottedList
--eval env (DottedList _ _) = error "Implement eval on DottedList" -- FIX
eval _ badForm = throwError $ BadSpecialForm "Unrecognised special form" badForm

apply :: Val -> [Val] -> ThrowError Val
apply (PrimitiveFunc func) args = func args
apply (Func params' varArg' body' closure) args =
  if num params' /= num args && isNothing varArg'
    then throwError $ NumArgs (num params') args
    else do
      env <- liftIO $ bindVars closure $ zip params' args
      env' <- bindVarArgs varArg' env
      evalBody env'
  where
    num xs = genericLength xs :: Integer
    remainingArgs = drop (length params') args
    bindVarArgs arg env = case arg of
      Just argName -> liftIO $ bindVars env [(argName, List remainingArgs)]
      Nothing -> return env
    evalBody env = last <$> mapM (eval env) body'
apply notF _                    = throwError $ NotFunction "Not a function" notF

-- =============================================================================
-- Primitives
-- =============================================================================

primitives :: [(String, PrimF)]
primitives =
  [("+", numericBinop (+))
  ,("-", numericBinop (-))
  ,("*", numericBinop (*))
  ,("/", numericBinop div)
  ,("mod", numericBinop mod)
  ,("quotient", numericBinop quot)
  ,("remainder", numericBinop rem)
  ,("symbol?", predicate isSymbol)
  ,("list?", predicate isList)
  ,("boolean?", predicate isBoolean)
  ,("number?", predicate isNumber)
  ,("real?", predicate isReal)
  ,("char?", predicate isChar)
  ,("null?", predicate isNull)
  ,("symbol->string", f1e symbolToString)
  ,("string->symbol", f1e stringToSymbol)
  ,("=", numBoolBinOp (==))
  ,("<", numBoolBinOp (<))
  ,(">", numBoolBinOp (>))
  ,("/=", numBoolBinOp (/=))
  ,(">=", numBoolBinOp (>=))
  ,("<=", numBoolBinOp (<=))
  ,("&&", boolBoolBinOp (&&))
  ,("||", boolBoolBinOp (||))

  ,("string?", predicate isString)
  ,("string=?", strBoolBinOp (==))
  ,("string<?", strBoolBinOp (<))
  ,("string>?", strBoolBinOp (>))
  ,("string<=?", strBoolBinOp (<=))
  ,("string>=?", strBoolBinOp (>=))
  ,("string-ref", stringRef)

  ,("car", f1e car)
  ,("cdr", f1e cdr)
  ,("length", f1e sLength)
  ,("cons", f2e cons)
  ,("eq?", f2b equal)
  ,("eqv?", f2b equal)
  ,("equal?", f2b equal)

  ,("apply", sApply)

  ,("print", f1e sPrint)

  ,("sleep", f1e sSleep)
  ]

type Predicate = Val -> Bool

f1e :: (Val -> ThrowError Val) -> PrimF
f1e f [obj] = f obj
f1e _ args  = throwError $ NumArgs 1 args

f2e :: (Val -> Val -> ThrowError Val) -> PrimF
f2e f [obj1, obj2] = f obj1 obj2
f2e _ args         = throwError $ NumArgs 2 args

f2b :: (Val -> Val -> Bool) -> PrimF
f2b f [obj1, obj2] = return $ Boolean $ f obj1 obj2
f2b _ args         = throwError $ NumArgs 2 args

f1 :: (Val -> Val) -> PrimF
f1 f [obj] = return $ f obj
f1 _ args  = throwError $  NumArgs 1 args

predicate :: Predicate -> PrimF
predicate p = f1 (Boolean . p)

sApply :: PrimF
sApply [f, List args] = apply f args
sApply (f: args)      = apply f args
sApply args           = throwError $ NumArgs 1 args

isSymbol :: Predicate
isSymbol (Symbol _) = True
isSymbol _        = False

isString :: Predicate
isString (String _) = True
isString _          = False

-- FIX: Must inspect structure of list, ending with '().
isList :: Predicate
isList (List _)         = True
isList _                = False

isBoolean :: Predicate
isBoolean (Boolean _) = True
isBoolean _           = False

isNumber :: Predicate
isNumber (Number _)  = True
isNumber _           = False

isReal :: Predicate
isReal (Float _)   = True
isReal _           = False

isChar :: Predicate
isChar (Char _)   = True
isChar _          = False

isNull :: Predicate
isNull (List []) = True
isNull _         = False

boolBinOp :: (Val -> ThrowError a) -> (a -> a -> Bool) -> PrimF
boolBinOp unpacker op [l, r] = do
  ul <- unpacker l
  ur <- unpacker r
  return $ Boolean $ ul `op` ur
boolBinOp _ _ args = throwError $ NumArgs 2 args

numBoolBinOp :: (Integer -> Integer -> Bool) -> PrimF
numBoolBinOp = boolBinOp unpackNum

strBoolBinOp :: (String -> String -> Bool) -> PrimF
strBoolBinOp = boolBinOp unpackStr

boolBoolBinOp :: (Bool -> Bool -> Bool) -> PrimF
boolBoolBinOp = boolBinOp unpackBool

numericBinop :: (Integer -> Integer -> Integer) -> PrimF
numericBinop _ args@[] = throwError $ NumArgs 1 args
numericBinop op args = (Number . foldl1' op) <$> mapM unpackNum args

unpackNum :: Val -> ThrowError Integer
unpackNum (Number n) = return n
unpackNum v          = throwError $ TypeMismatch "number" v

unpackStr :: Val -> ThrowError String
unpackStr (String s) = return s
unpackStr v          = throwError $ TypeMismatch "string" v

unpackBool :: Val -> ThrowError Bool
unpackBool (Boolean b) = return b
unpackBool v          = throwError $ TypeMismatch "boolean" v

symbolToString :: Val -> ThrowError Val
symbolToString (Symbol a) = return $ String a
symbolToString v        = throwError $ TypeMismatch "symbol" v

stringToSymbol :: Val -> ThrowError Val
stringToSymbol (String s) = return $ Symbol s
stringToSymbol v          = throwError $ TypeMismatch "string" v

car :: Val -> ThrowError Val
car (List (x : _))         = return x
car (DottedList (x : _) _) = return x
car v                      = throwError $ TypeMismatch "pair" v

cdr :: Val -> ThrowError Val
cdr (List (_:xs))           = return $ List xs
cdr (DottedList [_] x)      = return x
cdr (DottedList (_ : xs) x) = return $ DottedList xs x
cdr v                       = throwError $ TypeMismatch "pair" v

sLength :: Val -> ThrowError Val
sLength (List xs) = return $ Number $ genericLength xs
sLength v         = throwError $ TypeMismatch "list" v

cons :: Val -> Val -> ThrowError Val
cons x (List []) = return $ List [x]
cons x (List xs) = return $ List $ x : xs
cons x (DottedList xs l) = return $ DottedList (x : xs) l
cons a b = return $ DottedList [a] b

stringRef :: PrimF
stringRef [String s, Number n] = if n < 0 || n >= genericLength s
                                 then throwError $ Default $ "string-ref: Index out of bounds, " ++ show n ++
                                                                    " (length " ++ show (length s) ++ ")"
                                 else return $ Char $ s !! fromInteger n
stringRef args@[_, _]          = throwError $ Default $ "string-ref expects a string and an integer, got" ++ show args
stringRef args                 = throwError $ NumArgs 2 args

equalList :: [Val] -> [Val] -> Bool
equalList (a:as) (b:bs) = equal a b && equalList as bs
equalList [] []         = True
equalList _ _           = False

equal :: Val -> Val -> Bool
equal (Symbol a1) (Symbol a2)               = a1 == a2
equal (Boolean a1) (Boolean a2)             = a1 == a2
equal (Number a1) (Number a2)               = a1 == a2
equal (Float a1) (Float a2)                 = a1 == a2
equal (String a1) (String a2)               = a1 == a2
equal (Char a1) (Char a2)                   = a1 == a2
equal (DottedList a1 l1) (DottedList a2 l2) = equalList a1 a2 && equal l1 l2
equal (List a1) (List a2)                   = equalList a1 a2
equal _ _                                   = False

unit :: Val
unit = List []

sPrint :: Val -> ThrowError Val
sPrint v = do
  _ <- liftIO $ print v
  return unit

sSleep :: Val -> ThrowError Val
sSleep (Number n) = do
  _ <- liftIO $ threadDelay (fromInteger n * 1000 * 1000)
  return unit
sSleep x = throwError $ TypeMismatch "Expected Number in argument to sleep" x

readExprsFile :: String -> ThrowError [Val]
readExprsFile fileName = do
  contents <- liftIO $ readFile fileName
  readExprs contents

runFile :: Env -> String -> EitherT Err IO Val
runFile env fileName = do
  contents <- liftIO $ readFile fileName
  exprs <- readExprs contents
  vals <- mapM (eval env) exprs
  return $ last vals

primitiveEnv :: IO Env
primitiveEnv = do
  env <- newEnv
  bindVars env (map t primitives)
    where
      t (name, f) = (name, PrimitiveFunc f)

-- =============================================================================
-- REPL
-- =============================================================================

showVal :: Val -> String
showVal (String s) = show s
showVal (Symbol name) = name
showVal (Number n) = show n
showVal (Float f) = show f
showVal (Char ' ') = "#\\space"
showVal (Char '\n') = "#\\newline"
showVal (Char c) = "#\\" ++ [c]
showVal (Boolean True) = "#t"
showVal (Boolean False) = "#f"
showVal (List cs) = "(" ++ unwordsList cs ++ ")"
showVal (Port _)  = "<IO port>"
showVal (DottedList hd tl) = "(" ++ unwordsList hd ++ " . " ++ showVal tl ++ ")"
showVal (PrimitiveFunc _) = "<primitive>"
showVal Func {funcParams = params, funcVarArg = varArg} =
  "(lambda (" ++ unwords (map show params) ++
    (case varArg of
      Nothing -> ""
      Just arg -> " . " ++ arg) ++ ") ...)"

instance Show Val where show = showVal

unwordsList :: [Val] -> String
unwordsList = unwords . map showVal

--
-- read
--

readExprP :: Parser a -> String -> ThrowError a
readExprP parser input = case parse parser "schemey" input of
  Left err -> throwError $ Parser err
  Right val -> return val

readExpr :: String -> ThrowError Val
readExpr = readExprP parseExpr

readExprs :: String -> ThrowError [Val]
readExprs = readExprP (endBy parseExpr spaces)

readEval :: Env -> String -> ThrowError Val
readEval env s = readExpr s >>= eval env

prVal :: EitherT Err IO Val -> IO ()
prVal et = do
  e <- runEitherT et
  case e of
    Left err         -> print err
    Right (List [])  -> putStr "" -- avoid printing '()
    Right v          -> print v

readEvalPrint :: Env -> IO Bool
readEvalPrint env = do
  putStr "schemey> " >> hFlush stdout
  end <- isEOF
  if end
     then putStrLn "" >> return True
     else do
       expr <- getLine
       if null expr
          then return False
          else prVal (readEval env expr) >> return False

-- read+eval+print+loop
repl :: Env -> IO ()
repl env = do
  quit <- readEvalPrint env `catch` onUserInterrupt
  unless quit $ repl env

onUserInterrupt :: AsyncException -> IO Bool
onUserInterrupt UserInterrupt = putStrLn "\nquitting..." >> return True
onUserInterrupt e = throw e

usage :: IO ()
usage = putStrLn "usage: schemey [-h] [-e scheme-expression] [filename args...]"

main :: IO ()
main = do
  args <- getArgs
  env <- primitiveEnv
  case args of
    []              -> repl env
    ["-e", expr]    -> prVal $ readEval env expr
    ["-h"]          -> usage
    fileName : args' -> do
                         env' <- bindVars env [("args", List $ map String args')]
                         prVal $ runFile env' fileName
