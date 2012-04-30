-- Copyright (c) Tim Sheard
-- OGI School of Science & Engineering, Oregon Health & Science University
-- Maseeh College of Engineering, Portland State University
-- Subject to conditions of distribution and use; see LICENSE.txt for details.
-- Thu Mar  3 11:15:06 Pacific Standard Time 2005
-- Omega Interpreter: version 1.0

module CommentDef(cLine,cStart,cEnd,nestedC) where

-----------------------------------------------------------
-- In order to do layout, we need to "skip white space"
-- We need combinators that compute white space. Thus we
-- need to know how comments are formed. These constants
-- let us compute a whitespace parser. They fields in
-- TokenDef are derived from these definitions


-- Haskell Style
cStart = "{-"   -- (commentStart tokenDef)
cEnd   = "-}"   -- (commentEnd tokenDef)
cLine  = "--"   -- (commentLine tokenDef)
nestedC = True  -- (nestedComment tokenDef)


-- Java Style
{-
cStart	 = "/*"
cEnd	 = "*/"
cLine	 = "//"
nestedC = True
-}