# # `Palimdromes<:CombinedParser`: a Tutorial for writing your combinable Parser
# Palimdromes are an interesting example for parsing because
# intuitively programmers as well as laymen understand the problem: 
# the text is identical when read from left to right, as we are used to do,
# or when read from right to left in reverse, 
# when we read only the letters and discard all non-word characters.
#
# This example enables you to write your own custom `CombinedParser` based off a minimal template.
# ## 1. A non-word skipping palimdrome regex
# The PCRE test case contains nice examples of non-trivial palimdromes.
# The tested regular expression matching these palimdromes is cryptic and requires arcane reasoning even to the initiated.
#
using CombinedParsers
using CombinedParsers.Regexp
## defines parsers for pcre tests:
CombinedParsers.Regexp.@pcre_tests; 

pt = pcre_test"""
/^\W*+(?:((.)\W*+(?1)\W*+\2|)|((.)\W*+(?3)\W*+\4|\W*+.\W*+))\W*+$/i
    1221
 0: 1221
 1: 1221
 2: 1
    Satan, oscillate my metallic sonatas!
 0: Satan, oscillate my metallic sonatas!
 1: <unset>
 2: <unset>
 3: Satan, oscillate my metallic sonatas
 4: S
    A man, a plan, a canal: Panama!
 0: A man, a plan, a canal: Panama!
 1: <unset>
 2: <unset>
 3: A man, a plan, a canal: Panama
 4: A
    Able was I ere I saw Elba.
 0: Able was I ere I saw Elba.
 1: <unset>
 2: <unset>
 3: Able was I ere I saw Elba
 4: A
\= Expect no match
    The quick brown fox
No match
"""


# It is interesting that this case ignoring PCRE pattern matches palimdromes:
re = Regex(pt.pattern...)
# I figure the expression is hard to construct and come up with.
# The easy part is that the pattern needs to ignore case and whitespace `\W`.
## TODO: re"\W" show `UnicodeClass`
#
# The pattern makes intense use of backreferences and subroutines.
# ### Tree display of regex
# I find it hard to understand the compact captures `(.)`, even in a nested tree display:
cp = Regcomb(pt.pattern...)
# Why no backreference `\1`, why no subroutine `(?2)`?
# Theoretical linguists, I wonder, is the minimum number of capture groups 4, for a regular expression matching palimdromes?

# Matching example 3 is fast
using BenchmarkTools
@time match(re, pt.test[3].sequence)

# Writing a palimdrome parser should be easier.
# And with julia compiler it should be faster.
#
# In practice `CombinedParsers` [`Regcomb`](@ref) of the regular expression will detect palimdromes too.
# Palimdrome matching provides an interesting cross-parser performance benchmark.
@time match(cp, pt.test[3].sequence)
# `CombinedParsers.Regexp.Subroutine` matching is slow because the current implementation is using state-copies of captures.
# (TODO: could be a stack?).

# ## 2. A non-word skipping `Palimdrome<:CombinedParser`
# This example of `Palimdrome<:CombinedParser` is a much faster palimdrome parser and more interesting and more easy to write.
# It mimics the human readable palimdrome rule that is clear and quite easy to comprehend:
#
# the text is identical when read from left to right, as we are used to do,
# or when read from right to left in reverse,
# when we read only the letters and skip all non-word characters.
#
# This rule is efficient programming in natural language.
# After defining the parser, the third part of the example discusses the design of match iteration in `CombinedParsers`.
# #### Prerequisite: Skipping whitespace
# For the string `"two   words"`,  from the point of index 4 (`' '` after "from") the next word character after skipping whitespace left and right are indices of 3 (tw`o`) and 7 (`w`ords).
# In Julia syntax, this is expressed in terms of `direction` (functions `Base.prevind` and `Base.nextind` return next index to left or right), and `word_char::T`, what makes up a word character (provided method `CombinedParser.ismatch(char,parser::T)::Bool`.)

@inline function seek_word_char(direction,str,i,
                                till=lastindex(str),
                                word_char=UnicodeClass(:L))
    i=direction(str,i)
    while i>0 && i<=till && !CombinedParsers.ismatch((@inbounds str[i]),word_char)
        i=direction(str,i)
    end
    return i
end
( prev_index=seek_word_char(prevind, "two   words", 4),
  next_index=seek_word_char(nextind, "two   words", 4) )

# ### Subtyping `<: CombinedParser`
struct Palimdrome{P} <: CombinedParser{SubString}
    word_char::P
    Palimdrome(x) = new{typeof(x)}(x)
    ## UnicodeClass(:L) creation currently is slow, but required only once by default.
    Palimdrome() = Palimdrome(UnicodeClass(:L))
end
## @btime UnicodeClass(:L)


# ### Matching
# A custom parser needs a method to determine if there is a match at a position, and its state.
# How can this be implemented for a palimdrome?
# There are two strategies:
# 1. inside-out:  expand left and right from position until word character left does not match word character at right. Succeed if a minimal length is met. Fail otherwise.
# 2. outside-in: start left and right, move positions towards middle until they are at word characters and succeed if left and right positions meet, compare these characters, and proceed to the next positions if the word characters match or fail if there is a mismatch. (This might be [the-fastest-method-of-determining-if-a-string-is-a-palindrome](https://stackoverflow.com/questions/21403782/the-fastest-method-of-determining-if-a-string-is-a-palindrome).  But I figure finding all palimdrome matches in a string is slow because you would be required to test for all possible substrings.)
# The inside out strategy seems easier and faster.

# ### Matching greedy
# With the inside-out stratedy, the implementation greedily expands over non-word characters.
# The state of a match will be represented as
import CombinedParsers: state_type
CombinedParsers.state_type(::Type{<:Palimdrome}) =
    NamedTuple{(:left,:center,:right),Tuple{Int,Int,Int}}

# For the inside-out strategy the `Palimdrome<:CombinedParser` is a parser that looks behind the current index.
# The start index of a palimdrome match is its center.
Base.prevind(str,after::Int,p::Palimdrome,state) =
    state.center
Base.nextind(str,i::Int,p::Palimdrome,state) =
    nextind(str,state.right)
# `prevind` and `nextind` methods for a custom parser are required during the match iteration process.
 
# Computing the first match at `posi`tion is done by method dispatch `_iterate(parser::Palimdrome,str,till,posi,after,state::Nothing)`.
function CombinedParsers._iterate(x::Palimdrome,
                                  str, till,
                                  posi, after,
                                  state::Nothing)
    right_ = left_ = left = right = posi
    while left>0 && right<=till && lowercase(@inbounds str[left])==lowercase(@inbounds str[right])
        ## if we cannot expand, we can succeed with current (left_,right_)
        right_ = right 
        left_ = left
        left =  seek_word_char(
            prevind,str,
            left,till,x.word_char)        
        right = seek_word_char(
            nextind,str,
            right,till,x.word_char)
    end
    left, left_, right_, right
    if left_ == right_ 
        nothing
    else
        tuple(nextind(str,right_),
              (left=left_, center=posi, right=right_))
    end
end

# (Feedback appreciated: Would is be more efficient change the `_iterate` internal API for the first match to arity 4?)
# The internal API calls (for the center index 18):
# TODO: state = _iterate(Palimdrome(),s,18)
# _iterate matches the right part of the palimdrome iif posi at the center of a palimdrome. 
# - greedily expand status and parsing position over non-word characters.
s=pt.test[3].sequence
state = _iterate(Palimdrome(),s,lastindex(s),18,18,nothing)

# ### `match` and `get`
# [`_iterate`](@ref) is called when the public API `match` or `parse` is used.
# Match searches for a center index and then matched the right part of the palimdrome. 
p = Palimdrome()
m = match(p,s)



# The result of a parsing is the matching substring from left to right, 
# implementing `Base.get` with the full argument range:
Base.get(x::Palimdrome, str, till, after, posi, state) =
    SubString(str,state.left,state.right)

# The match result is matching the first palimdrome, which is short and simple - but not what we want.
get(m)

# ### Iterating through matches
# The longest palimdrome is matched too:
p = Palimdrome()
[ get(m) for m in match_all(p,s) ]


# To skip trivial short palimdromes we can use `Base.filter` 
long_palimdrome = filter(Palimdrome()) do sequence, till, posi, after, state
    state.right-state.left+1 > 5
end
get(match(long_palimdrome,s))

# ## Iteration of smaller Sub-palimdromes
# The set of all palimdromes in a text includes the shorter palimdromes contained in longer ones.
# Provide a method to iterate the previous state:
"Shrinking `state` match"
function CombinedParsers._iterate(x::Palimdrome, str, till, posi, after, state)
    left_, posi_, right_ = state
    left =  seek_word_char(
        nextind,str,
        left_,till,x.word_char)
    right = seek_word_char(
        prevind,str,
        right_,till,x.word_char)
    if left >= right # left == posi
        nothing
    else
        tuple(nextind(str,right),
              (left=left, center=posi_, right=right))
    end
end

[ get(m) for m in match_all(p,s) ]

# Note that the previous greedy-only behaviour is atomic on terms of regular expression, which can be restored with [`Atomic`](@ref)
p = Atomic(Palimdrome())
get.(match_all(p,s)) |> collect

# ## Padding and combining
# Note that the PCRE pattern included outside non-words, specifically the tailing `!`.
re = Regex(pt.pattern...)
match(re,s)

# ``CombinedParsers` are designed with iteration in mind, and a small match set reduces computational time when iterating through all matches.
# `Palimdrome` matches palimdromes with word-char boundaries.
# The PCRE pattern includes non-words matches in the padding of palimdromes, a superset of `Palimdrome`.
# PCRE-equivalent matching can be achieved by combining the stricly matching `Palimdrome` with parsers for the padding.
padding=Repeat(CharNotIn(p.parser.word_char))
match_all(p*padding*AtEnd(),s) |> collect

# TODO: Memoization here!
# `Palimdrome` matches from center to right, like a lookbehind parser.
# A prefix parser to the left requires a parser for the left-part coupled by filter:
palimdrome = filter(
    Sequence(
        2,
        Lazy(Repeat(AnyChar())),
        Atomic(Palimdrome()))) do sequence, till, posi, after, state
            posi==state[2][1]
        end

# Now we can assert AtStart
p = AtStart() * padding * (palimdrome) * padding * AtEnd()
parse(p,s)

## Next...
# - match also palimdromes with odd number of letters
# - elaborate on iteration documentation
# - comparative benchmarking, conditional on palimdrome length
