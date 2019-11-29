module ParserAlchemy

using Parameters
using Nullables

using TextParse
import TextParse: tryparsenext
using BasePiracy

export tryparsenext, tokenize, result_type

export trimstring
trimstring(x::AbstractString) =
    replace(x, r"^[ \r\n\t]*|[ \r\n\t]*$" => s"")


############################################################
## Parsing with TextParse.AbstractToken, operators

ParserTypes = Union{TextParse.AbstractToken, AbstractString, Regex,
                    Pair{Symbol,
                         <:Union{TextParse.AbstractToken, AbstractString, Regex}}}
result_type(x::T) where {T<:ParserTypes} =
    result_type(T)
# Parser = Union{TextParse.AbstractToken}

## import Regex: match
export match
Base.match(r::TextParse.AbstractToken, str) =
    match(Regex(regex_string(r)), str)

export tokenize
tokenize(x, str::RegexMatch) = tokenize(x, str.match)


struct PartialMatchException <: Exception
    index::Int
    str::String
end
export context
context(x::PartialMatchException, delta = 200) =
    x.str[min(x.index,end):min(end, nextind(x.str,x.index,delta))]
import Base: showerror
function Base.showerror(io::IO, x::PartialMatchException)
    println(io, "incomplete parsing at $(x.index):")
    println(io, "\"$(context(x))\"")
    println(io, "in \"$(x.str)\"")
end

"""
tokenize(x, str; delta=200, errorfile=nothing)

Tokenize string or iterator `str` with parser `x`.
"""
function tokenize(x, str; partial=:error)
    i=firstindex(str)
    till=lastindex(str)
    r, i_ = tryparsenext(x, str, i, till, TextParse.default_opts)
    if i_<=till
        if partial isa AbstractString ## remove?
            make_org(s) = replace(s, r"^\*"m => " *")
            open(partial, "a") do io
                println(io, "* incomplete parsing stopped at $i_ ")
                println(io, "error at")
                println(io, make_org(str[min(i_,end):min(end, nextind(str,i_,200))]))
                println(io, "** data")
                println(io, make_org(str))
            end
        elseif partial == :warn
            @warn "incomplete parsing stopped at $i_ " str[min(i_,end):min(end, nextind(str,i_,200))]
        elseif partial == :error
            throw(PartialMatchException(i_, str))
        end
    end
    if isnull(r)
        if partial == :error
            error("no match")
        elseif partial == :warn
            @warn "no match"
        else
            nothing
        end
    else
        get(r)
    end
end

import Base: Regex
function Regex(x::ParserTypes) 
    Regex("^"*regex_string(x))
end

export opt, seq, rep, rep_splat, rep1, alt

export NamedToken
struct NamedToken{P,T} <: TextParse.AbstractToken{Pair{Symbol,T}}
    name::Symbol
    parser::P
end

function TextParse.tryparsenext(tok::NamedToken{P,T}, str, i, till, opts=TextParse.default_opts) where {P,T}
    result, i_ = tryparsenext(tok.parser, str, i, till, opts)
    if isnull(result)
        Nullable{Pair{Symbol,T}}(), i
    else
        ## cz@show tok (result)
        Nullable(tok.name => get(result)), i_
    end
end


############################################################
## Transformations

log_transform(transform, log, catch_error=false) =
    if catch_error
        (v,i) -> try
            r=transform(v,i)
            log && @info "transformed" transform v r
            return r
        catch f
            @error "transform error: " f RT v tokens transform
            rethrow(f)
        end
    elseif log
        (v,i) -> begin
            r=transform(v,i)
            @info "transformed" transform v r
            return r
        end  
    else
        transform
    end

export InstanceParser, instance
struct InstanceParser{P,T, F<:Function} <: TextParse.AbstractToken{T}
    transform::F
    parser::P
end
InstanceParser{T}(transform::F, p::P) where {T, F<:Function,P} = InstanceParser{P,T,F}(transform, p)


function TextParse.tryparsenext(tok::InstanceParser{P,T}, str, i, till, opts=TextParse.default_opts) where {P,T}
    result, i_ = tryparsenext(tok.parser, str, i, till, opts)
    if isnull(result)
        Nullable{T}(), i
    else
        ## cz@show tok (result)
        Nullable(
            tok.transform(get(result), i)), i_
    end
end



export instance 

function instance(::Type{T}, p::P, a...) where {T, P<:ParserTypes}
    InstanceParser{T}((v,i) -> T(a..., v), p)
end
function instance(::Type{T}, p::P) where {T, P<:ParserTypes}
    InstanceParser{T}((v,i) -> _convert(T,v), p)
end
function instance(::Type{T}, f::Function, p::P, a...) where {T, P<:ParserTypes}
    InstanceParser{T}((v,i) -> _convert(T,f((v), i, a...)), p)
end

include("namedtuples.jl")

struct TokenizerOp{op, T, E,F<:Function} <: TextParse.AbstractToken{T}
    els::E
    f::F
end

quantifier(x::TokenizerOp{:rep}) =  "*"
# quantifier(x::TokenizerOp{:rep_splat,T,E}) where {T, E}  = "*"
quantifier(x::TokenizerOp{:rep1}) =  "+"
quantifier(x::TokenizerOp{:opt}) = "?"

export Filter
"""
wraps a `parser::P`, succeeds if `parser` does succeed and a predicate function returns true on the match, otherwise fails.
Useful for checks like "must not be followed by `parser`, don't consume its match".
"""
struct Filter{T,P,F<:Function} <: TextParse.AbstractToken{T}
    parser::P
    filter::F
end
Filter(f::Function,p::P) where P =
    Filter{result_type(P),P,typeof(f)}(p,f)
result_type(p::Type{Filter{T}}) where T = T

function TextParse.tryparsenext(tok::Filter, str, i, till, opts=TextParse.default_opts)
    result, i_ = tryparsenext(tok.parser, str, i, till, opts)
    if isnull(result)
        result, i
    elseif tok.filter(get(result))
        result, i_
    else
        Nullable{result_type(typeof(tok))}(), i
    end
end

export FullText
struct FullText <: TextParse.AbstractToken{AbstractString}
end
TextParse.tryparsenext(tok::FullText, str, i, till, opts=TextParse.default_opts) = 
    Nullable(str[i:till]), till+1



export PositiveLookahead
"""
wraps a `parser::P`, succeeds if and only if `parser` succeeds, but consumes no input.
The match is returned.
Useful for checks like "must be followed by `parser`, but don't consume its match".
"""
struct PositiveLookahead{T,P} <: TextParse.AbstractToken{T}
    parser::P
end
PositiveLookahead(p::P) where P = PositiveLookahead{result_type(P),P}(p)
result_type(p::Type{PositiveLookahead{T}}) where T = T

function TextParse.tryparsenext(tok::PositiveLookahead, str, i, till, opts=TextParse.default_opts)
    result, i_ = tryparsenext(tok.parser, str, i, till, opts)
    result, i
end

export Never
"""
wraps a `parser::P`, succeeds if and only if `parser` does not succeed, but consumes no input.
`nothing` is returned as match.
Useful for checks like "must not be followed by `parser`, don't consume its match".
"""
struct Never <: TextParse.AbstractToken{Nothing}
end

TextParse.tryparsenext(tok::Never, str, i, till, opts=TextParse.default_opts) =
    Nullable{Nothing}(), i

export Always
"""
wraps a `parser::P`, succeeds if and only if `parser` does not succeed, but consumes no input.
`nothing` is returned as match.
Useful for checks like "must not be followed by `parser`, don't consume its match".
"""
struct Always <: TextParse.AbstractToken{Nothing}
end

TextParse.tryparsenext(tok::Always, str, i, till, opts=TextParse.default_opts) =
    Nullable(nothing), i



export NegativeLookahead
"""
wraps a `parser::P`, succeeds if and only if `parser` does not succeed, but consumes no input.
`nothing` is returned as match.
Useful for checks like "must not be followed by `parser`, don't consume its match".
"""
struct NegativeLookahead{P} <: TextParse.AbstractToken{Nothing}
    parser::P
end

function TextParse.tryparsenext(tok::NegativeLookahead, str, i, till, opts=TextParse.default_opts)
    result, i_ = tryparsenext(tok.parser, str, i, till, opts)
    if isnull(result)
        ## @info "match at" str[i:till]
        Nullable(nothing), i
    else
        Nullable{Nothing}(), i
    end
end


export FlatMap
struct FlatMap{T,P,Q<:Function} <: TextParse.AbstractToken{T}
    left::P
    right::Q
    function FlatMap{T}(left::P, right::Q) where {T, P, Q<:Function}
        new{T,P,Q}(left, right)
    end
end

regex_string(x::FlatMap)  = error("regex determined at runtime!")
function TextParse.tryparsenext(tokf::FlatMap, str, i, till, opts=TextParse.default_opts)
    T = result_type(tokf)
    lr, i_ = tryparsenext(tokf.left, str, i, till, opts)
    if !isnull(lr)
        rightp = tokf.right(get(lr))
        !( result_type(rightp) <: T ) && error("$(result_type(rightp)) <: $T")
        rr, i__ = tryparsenext(rightp, str, i_, till, opts)
        if !isnull(rr)
            return rr, i__
        end
    end
    return Nullable{T}(), i
end


struct Sequence{T,P<:Tuple,F<:Function} <: TextParse.AbstractToken{T}
    parts::P
    transform::F
    function Sequence{T}(p::P, f::F) where {T, P<:Tuple,F<:Function}
        new{T,P,F}(p, f)
    end
end
parser_types(::Type{Sequence{T, P, F}}) where {T, P, F} =
    P

regex_string(x::Sequence)  = join([ regex_string(p) for p in x.parts])
@generated function TextParse.tryparsenext(tokf::Sequence, str, i, till, opts=TextParse.default_opts)
    pts = parser_types(tokf)
    ## Core.println(pts)
    subresult = Symbol[ gensym(:r) for i in fieldtypes(pts) ]
    parseparts = [
        quote
        $(subresult[i]), i_ = tryparsenext(parts[$i], str, i_, till, opts)
        if isnull($(subresult[i]))
        return Nullable{T}(), i
        end
        end
        for (i,t) in enumerate(fieldtypes(pts))
    ]
    ## Core.println( parseparts )
    quote
        T = result_type(tokf)
        i_ = i
        parts=tokf.parts
        $(parseparts...)
        R = tokf.transform(tuple( $([ :(($(s)).value) for s in subresult ]...) ), i)
        ( Nullable(_convert(T, R)), i_)
    end
end

# function TextParse.tryparsenext(tokf::TokenizerOp{:seq, T, E}, str, i, till, opts=TextParse.default_opts) where {T,E}
#     toks = tokf.els.parts
#     result=Vector{Any}(undef, length(toks))
#     i_::Int = i
#     for (j,t) in enumerate(toks)
#         r, i__ = tryparsenext(t, str, i_, till)
#         if !isnull(r)
#             ## @info "seq" str[i_:min(i__,end)] r.value typeof(toks[j]) str[min(i__,end):end]
#             @inbounds result[j] = r.value
#             i_ = i__
#         else
#             # @info "seq" str[i_:min(i__,end)] (toks[j]) str[min(i__,end):end]
#             ## j>1 && @info "abort match $j=$(toks[j])" (toks) str[i_:end]  i_, till result[j-1]
#             j>1 && tokf.els.partial && return ( Nullable(result[1:j-1]), i_)
#             return Nullable{T}(), i
#         end
#     end
#     ## @show result
#     R = tokf.f(result, i)
#     ## remove completely, fix in f
#     false && !isa_reordered(R, T) && let S = typeof(R)
#         @warn "transformed wrong " result R S T tokf
#     end
#     return ( Nullable(_convert(T, R)), i_)
# end


export rep_stop, rep_until
rep_stop(p,stop) =
    rep(seq(NegativeLookahead(stop),p; transform=2))
rep_until(p,until, with_until=false) =
    seq(rep_stop(p,until), until;
        transform = with_until ? nothing : 1)

export regex_string
regex_string(::TextParse.Numeric{<:Integer}) = "[[:digit:]]+"
regex_string(x::Union{NamedToken, InstanceParser}) = regex_string(x.parser)
regex_string(x::Pair{Symbol,T}) where T = regex_string(x.second)
function regex_string(x::Regex)
    p=x.pattern
    if p[1]=='^'
        p=p[2:end]
    end
    if p[end]=='$'
        p=p[1:end-1]
    end
    p
end

regex_string(x::TokenizerOp) = "(?:" * regex_string(x.els) * ")" * quantifier(x)
regex_string(x::TokenizerOp{:not,T,E}) where {T, E}  = regex_string(x.els[2])
regex_string(x::TokenizerOp{:opt,T,E}) where {T, E}  = regex_string(x.els.parser)
regex_string(x::TokenizerOp{:tokenize,T,E}) where {T, E}  = regex_string(x.els.outer)
regex_string(x::TokenizerOp{:alt,T,E}) where {T, E}  = "(?:" * join([ regex_string(p) for p in x.els],"|") * ")"



export parser
parser(x::TextParse.AbstractToken) = x
revert(x::TextParse.AbstractToken) = error("implement!")
parser(v::Vector) = [ parser(x) for x in v ]

struct Suffix{S} s::S end
parser(x::AbstractString) = x
revert(x::AbstractString) = Suffix(x)
regex_flags(x) = replace(string(x), r"^.*\"([^\"]*)$"s => s"\1")
parser(x::Regex) = Regex("^" * regex_string(x), regex_flags(x))
revert(x::Regex) = Regex(regex_string(x) * '$', regex_flags(x))
parser(x::Pair{Symbol, P}) where P =
    NamedToken{P,result_type(P)}(x.first, parser(x.second))

parser(t::Tuple) = tuple([ parser(x) for x in t ]...)
parser(x::Pair{Symbol, Tuple{P, Type}}) where P =
    NamedToken{P,x.second[2]}(x.first, x.second[1])


function TokenizerOp{op,T}(x::E, f::F) where {op, T, E, F<:Function}
    TokenizerOp{op,T,E,F}(x, f)
end

result_type(x::Type{<:TextParse.AbstractToken{T}}) where T = T
result_type(x::Type{Pair{Symbol, <:T}}) where T =
    Pair{Symbol, result_type(T)}
result_type(x::Type{<:AbstractString}) = AbstractString
result_type(x::Type{Regex}) = AbstractString


function opt(x...; 
             log=false,
             transform_seq=(v,i) -> v, kw...)
    ## @show transform_seq
    if length(x)==1
        els = parser(x[1])
    else
        ## @show x
        els = seq(x...; transform=transform_seq,
                  log=log)
    end
    opt(els; log=log, kw...)
end

opt(x; kw...) =
    opt(result_type(typeof(x)), x; kw...)

defaultvalue(::Type{<:AbstractString}) = ""
defaultvalue(V::Type{<:Vector}) = eltype(V)[]
defaultvalue(V::Type{<:VectorDict}) = VectorDict{keytype(V), valtype(V)}(eltype(V)[])
defaultvalue(V::Type) = missing

function opt(T::Type, x;
             default=defaultvalue(T),
             log=false,
             transform=(v,i) -> v) where { D }
    ##@show default
    x=parser(x)
    RT = promote_type(T,typeof(default))
    TokenizerOp{:opt,RT}(
        (parser=x, default=default),
        log_transform(transform, log))
end

function alt(x::Vararg{ParserTypes})
    parts = Any[ parser(y) for y in x ]
    T = promote_type([ result_type(typeof(x)) for x in parts]...)
    TokenizerOp{:alt,T}(parts, (v,i) -> v)
end

function alt(x::Vararg{Union{String,Regex}})
    T = AbstractString
    instance(T, (v,i) -> v, Regex("^(?:" * join([regex_string(p) for p in x], "|") *")"))
end

function alt(T::Type, x::Vararg; log=false, transform=(v,i) -> v)
    TokenizerOp{:alt,T}(
        (Any[ parser(y) for y in x ]), log_transform(transform, log))
end

## @deprecate join_seq(tokens::Vararg; kw...) seq(tokens...; transform=seq_join, kw...)
## import Base.map
## Base.map(f::Function) = x -> map(f,x)

function seq(tokens::Vararg{ParserTypes};
             transform=nothing, kw...)
    parts = tuple( ( parser(x) for x = tokens )... )
    T = [ result_type(typeof(x)) for x in parts]
    ## error()
    if transform isa Integer
        seq(T[transform], parts...; 
            transform = (v,i) -> v[transform], kw...)
    elseif transform===nothing
        seq(Tuple{(T...)}, parts...; 
            transform = (v,i) -> tuple(v...), kw...)
    else
        seq(Tuple{(T...)}, parts...; 
            transform = transform, kw...)
    end
end

# struct InnerParser{I,P,T} <: TextParse.AbstractToken{T}
#     inner::I
#     outer::P
# end

function BasePiracy.construct(t::Type{NamedTuple{n,ts}}, v; kw...) where {n,ts}
    vs = Any[ remove_null(x) for x in v ]
    kvs = VectorDict(Pair{Symbol}[ x
                                   for x in vs
                                   if (x isa Pair && x.first !=:_match) ])
    ks = Any[ x.first for x in kvs ]
    NamedTuple{n, ts}(tuple([ let fn = fieldname(t,i)
                              _convert(fieldtype(t, i),
                                       get(kw, fn) do
                                       get(kvs, fn, :missing)
                                       end)
                              end
                              for i =1:length(n) ]...) )
end
    
function seq(T::Type, tokens::Vararg;
             combine=false, outer=nothing,
             partial = false,
             log=false,
             transform=:instance, kw...)
    parts = tuple( ( parser(x) for x = tokens )... )
    ## todo: tuple?    
    if combine
        if outer===nothing
            outer = Regex("^"*join([ "("*regex_string(x)*")" for x in parts ]))
        else
            @assert outer==join([ "("*regex_string(x)*")" for x in parts ])
        end
    end
    if T==NamedTuple
        fnames = tuple( [ x.name for x in parts if x isa NamedToken ]... )
        ftypes = [ result_type(typeof(x.parser)) for x in parts if x isa NamedToken ]
        RT = isempty(fnames) ? T : NamedTuple{fnames, Tuple{ftypes...}}
    else
        RT = T
    end
    if transform == :instance
        transform = (v,i) -> construct(RT,v)
    end
    tr = log_transform(transform, log)
    result = Sequence{RT}(parts, tr)
    if outer === nothing
        result
    else
        if true || regex_string(result) == regex_string(outer)
            re_inner = ( "^" * join([ "(" * regex_string(t) * ")" for t in parts ])) ## when??? * '$' )             
            ## @warn "compiling regex" re Regex(re_inner) maxlog=1
            TokenizerOp{:seq_combine, RT}(  ( outer=outer::Regex,
                                              parts=parts, log=log, partial=partial ) , tr)
        else
            tok(outer, result)
            # instance(RT, (v,i) -> tokenize(result, v), outer)
        end
    end
end

export tok
tok(outer::Regex, result::TextParse.AbstractToken{T}) where T =
    TokenizerOp{:tokenize, T}(  ( outer=parser(outer), parser=result ), identity )

@deprecate rep_splat(x) TokenizerOp{:rep_splat,String}([parser(x)])
# rep(x)

rep1(x::ParserTypes;  kw...) where T =
    rep1(Vector{result_type(typeof(x))},x; kw...)
rep1(T::Type, x;  log=false, transform=(v,i) -> v) =
    TokenizerOp{:rep1,T}(parser(x), log_transform(transform, log))


rep1(T::Type, x,y::Vararg; log=false, transform=(v,i) -> v, kw...) =
    rep1(T, seq(x,y...; transform=log_transform(transform, log), kw...), transform=(v,i) -> v)

rep(x::T; kw...) where T =
    rep(Vector{result_type(T)},x; kw...)
    
rep(x::TextParse.AbstractToken{T};  kw...) where T =
    rep(Vector{T},x; kw...)

rep(T::Type, x;  log=false, transform=(v,i) -> v ) = #[ convert(T,i) for i in v ] ) =
    TokenizerOp{:rep,T}(parser(x), log_transform(transform, log))

rep(x::Regex) =
    Regex(regex_string(rep(x; log=false)))


rep(T::Type, x,y::Vararg; log=false, transform=(v,i) -> v, kw...) =
    rep(T, seq(x,y...; transform=log_transform(transform, log), kw...); transform=(v,i) -> v)

# rep(x) =
#     TokenizerOp{:rep,String}([parser(x)], seq_vcat)
# rep(x,y::Vararg; transform=seq_vcat, kw...) =
#     rep(seq(x,y...; transform=transform, kw...); transform=seq_vcat, kw...)
# rep(f::Function,x) =
#     TokenizerOp{:rep,String}([parser(x)],f)


export not
"""
will always return a string
"""
not(exclude, from;  log=false) =
    TokenizerOp{:not,String}( ## todo: result_type(from)
        (parser(exclude), Regex("^"*regex_string(from))),
        (v,i) -> v)

# cutright(full,tokens::Vararg) =
#     TokenizerOp{:cutright,String}([parser(full),
#                                    [ parser(x,reverse=true) for x = tokens ]...])



import Base: (*), (|), cat
(*)(x::Regex, y::Regex) =
    Regex(x.pattern * y.pattern)
(*)(x::String, y::Regex) =
    Regex(regex_escape(x) * y.pattern)
(*)(x::Regex, y::String) =
    Regex(x.pattern * regex_escape(y))

#(*)(x::TokenizerOp{op,T,F}, y::P) where {op,T,F,P} =
#    TokenizerOp{:seq,T}([x,parser(y)])
# (*)(x::P, y::TokenizerOp) where {P} = seq(x,y)



(*)(x::Any, y::TextParse.AbstractToken) = seq(parser(x),y)
(*)(x::TextParse.AbstractToken, y::Any) = seq(x,parser(y))
(*)(x::TextParse.AbstractToken, y::TextParse.AbstractToken) = seq(x,y)

(|)(x::Regex, y::Regex) =
    Regex("(?:",x.pattern * "|" * y.pattern * ")")
(|)(x::String, y::Regex) =
    Regex("(?:",regex_escape(x) * "|" * y.pattern * ")")
(|)(x::Regex, y::String) =
    Regex("(?:",x.pattern * "|" * regex_escape(y) * ")")


(|)(x::Any, y::TextParse.AbstractToken) = alt(parser(x),y)
(|)(x::TextParse.AbstractToken, y::Any) = alt(x,parser(y))
(|)(x::TextParse.AbstractToken, y::TextParse.AbstractToken) = alt(x,y)




# function Base.show(io::IO, v::Vector{<:ParserTypes})
#     print(io, join(string.(v),", "))
# end




export regex_tempered_greedy, regex_neg_lookahead
# https://www.rexegg.com/regex-quantifiers.html#tempered_greed
regex_tempered_greedy(s,e, flags="s"; withend=true) =
    Regex("^"*regex_string(s)*"((?:(?!"*regex_string(e)*").)*)"*
          ( withend ? regex_string(e) : ""),flags)

# https://www.rexegg.com/regex-quantifiers.html#tempered_greed
regex_neg_lookahead(e, match=r".") =
    instance(String,
             (v,i) -> v[1],
             Regex("^((?:(?!"*regex_string(e)*")"*regex_string(match)*")*)","s"))

export regex_escape
## https://github.com/JuliaLang/julia/pull/29643/commits/dfb865385edf19b681bc0936028af23b1f282b1d
## escaping ##
"""
        regex_escape(s::AbstractString)
    regular expression metacharacters are escaped along with whitespace.
    # Examples
    ```jldoctest
    julia> regex_escape("Bang!")
    "Bang\\!"
    julia> regex_escape("  ( [ { . ? *")
    "\\ \\ \\(\\ \\[\\ \\{\\ \\.\\ \\?\\ \\*"
    julia> regex_escape("/^[a-z0-9_-]{3,16}\$/")
    "/\\^\\[a\\-z0\\-9_\\-\\]\\{3,16\\}\\\$/"
    ```
    """
function regex_escape(s)
    res = replace(string(s), r"([()[\]{}?*+\-|^\$\\.&~#\s=!<>|:])" => s"\\\1")
    replace(res, "\0" => "\\0")
end
regex_string(x::AbstractString) = regex_escape(x)



# import Base.join
# export join
# Base.join(f::Function, transform::Function, x, delim) = 
#     seq(transform, opt(delim), f(x * delim), opt(x))

export seq_vcat
seq_vcat(r, i) = seq_vcat(r)
seq_vcat(r::Nothing)  = [ ]
seq_vcat(r::T) where T = T[ (r) ]
seq_vcat(r::Vector) = vcat( [ ( seq_vcat( x )) for x in r]... )






############################################################


##import Base: findnext

export splitter
splitter(S, parse; transform_split = v -> tokenize(S, v), kw...) =
    splitter(Regex(regex_string(S)), parse;
             transform_split = transform_split, kw...)

function splitter(## R::Type,
                  split::InstanceParser{Regex,S},
                  parse::TextParse.AbstractToken{T};
                  log=false,
                  transform = (v,i) -> v) where {S, T}    
    transform_split = split.transform ## (v,i) -> v
    R = promote_type(S,T)
    function tpn(str, i, n, opts) ## from util.jl:_split
        ## @show str
        ## @show R
        strs = Vector{R}(undef, 0)#[]
        lstr = str[i:min(end,n)]
        r = eachmatch(split.parser, lstr)
        j = 0
        for m in r
            if j <= m.match.offset
                ## m.match.offset  is indexed at 0!!
                ## @show lstr nextind(lstr,j) m.match.offset m.match
                before = SubString(lstr,nextind(lstr,j),prevind(lstr, m.match.offset + (transform_split===nothing ? sizeof(m.match) : 1)))
                log && @info "before" before
                push!(strs, (tokenize(parse, before))) # , i+nextind(lstr,j))) ## todo pass pos!
            end
            if transform_split!==nothing
                log && @info "split" before
                push!(strs, ( transform_split(m, i))) # , i+j) )
            end
            j = m.match.offset + sizeof(m.match) # =.ncodeunits
        end
        ## j = prevind(lstr,j)
        if j <= n-i
            after = SubString(str,i+j,min(lastindex(str),n))
            log && @info "after" after
            push!(strs,
                  (tokenize(parse, after))) ## , i+j)) ## todo pass pos!
        end
        result = transform(strs,i)
        ## error()
        log && @info "split" lstr strs result i j n
        return Nullable(result), nextind(str,n)
    end
    CustomParser(tpn, R)
end

function TextParse.tryparsenext(tok::AbstractString, str::AbstractString, i, till, opts=TextParse.default_opts)
    if startswith(str[i:end], tok)
        e = nextind(str, i, lastindex(tok))
        Nullable(tok), e
    else
        Nullable{String}(), i
    end
end

function TextParse.tryparsenext(tok::Regex, str, i, till, opts=TextParse.default_opts)
    m = match(tok, str[i:end]) ## idx not working with ^, and without there is no option to force it at begin
    if m === nothing
        Nullable{AbstractString}(), i
    else
        ni = m.match =="" ? i : nextind(str, i, length(m.match))
        ##@show str[i:min(end,ni)] m str[min(end,ni):end]
        ( Nullable(isempty(m.captures) ? m.match : m.captures)
          , ni
          )
    end
end

function parser(outer::Regex, x::TokenizerOp{op, T, F}) where {op, T, F}
    TokenizerOp{op, T, F}((outer, x.els), x.f)
end

export pair_value
"""
pair_value?
transform all values as instances of pairs for key.
"""
function pair_value(key)
    v -> [ Symbol( j.value.second)
           for j in v
           if (j.value) isa Pair && key == j.value.first
           ]
end

@deprecate value_tag(key) pair_value(key)


# Base.convert(::Type{Nullable{Pair{Symbol, T}}}, x::Pair{Symbol, Nullable{S}}) where {T,S} =
#     isnull(x.second) ? Nullable{Pair{Symbol, T}}() :
#     Nullable(x.first => convert(T, x.second.value))

export greedy
function greedy(tokens...;
                alt = [],
                transform=(v,i) -> v, log=false)
    TokenizerOp{:greedy,Any}(
        (pairs=[tokens...], alt=alt), log_transform(transform, log))
end

function TextParse.tryparsenext(tokf::TokenizerOp{:greedy, T, F}, str, i, till, opts=TextParse.default_opts) where {T,F}
    sections=tokf.els.pairs
    RT(key, value) = if value[2] isa ParserTypes
        if Missing <: result_type(typeof(key))
            result_type(typeof(value[2]))
        else
            promote_type(result_type(typeof(key)), result_type(typeof(value[2])))
        end
    else
        result_type(typeof(key))
    end
    R = Dict([ value[1] => Vector{RT(key,value)}() for (key,value) in sections]...,
             [ key => Vector{result_type(typeof(value))}() for (key,value) in tokf.els.alt]...
             )
    hist = Any[]
    last_section = nothing
    last_content = nothing
    aggregator = :head
    function first_match(j)
        local repval, i__
        for (key, content) in sections
            repval, i__ = tryparsenext(key, str, j, till)
            !isnull(repval) && return key, content, repval, i__
        end
        return (first(sections)..., repval, i__)
    end
    head = nothing
    i_ = i ##isnull(1)
    while true
        key, content, r, i__ = first_match(i_)
        save = if isnull(r)
            cr, ci = if last_content === nothing || last_content === missing
                Nullable{T}(), i
            else
                tryparsenext(last_content, str, i_, till)
            end
            ai = 0
            while ai < lastindex(tokf.els.alt) && isnull(cr)
                ai = ai+1
                cr, ci = tryparsenext(tokf.els.alt[ai].second, str, i_, till)
            end
            if isnull(cr)
                return Nullable{T}(_convert(T, tokf.f(R,i))), i_
            elseif ai == 0
                push!(hist, get(cr))
                i__ = ci
                false
            else
                aggregator != :head && append!(R[aggregator],hist)
                hist = [get(cr)]
                (aggregator, last_content) = tokf.els.alt[ai]
                last_section = ai
            end
        else
            if last_section !== nothing
                append!(R[aggregator],hist)
            end
            hist = get(r) !== missing ? [get(r)] : Vector{RT(key,content)}()
            aggregator, last_content = content
            last_section = key
        end
        i_ = i__
    end
    error("unreachable")
end

## todo: replace with isequalfields?
export isa_reordered
isa_reordered(x::T,S::Type{NamedTuple{n2,t2}}) where {T, n2,t2} =
    all([ fieldtype(T,key) <: fieldtype(S,key)
          for key in n2 ])

isa_reordered(x::T,S::Type) where {T} =
    x isa S

regex_string(x::TokenizerOp{:seq_combine,T,F}) where {T, F}  = regex_string(x.els[1])
function TextParse.tryparsenext(tokf::TokenizerOp{:seq_combine, T, F}, str, i, till, opts=TextParse.default_opts) where {T,F}
    re, toks = tokf.els.outer, tokf.els.parts
    # inner regex compiled in els?
    m = match(re, str[i:end])
    m===nothing && return Nullable{Vector{Any}}(), i
    result=Vector{Any}(undef, length(toks))
    i_ = i 
    for j in 1:length(toks)
        r = if toks[j] isa Union{AbstractString, Regex}
            m.captures[j] ##, i+m.captures[j].offset))
        else
            tokenize((toks[j]), m.captures[j] === nothing ? "" : m.captures[j])
        end 
        if r !== nothing
            result[j] = r  ## todo: in tokenize! shift_match_start(, i_-1)
            i_ = i_ + sizeof(m.captures[j]) ##.ncodeunits
        else
            ##j>1 && @info "abort match" toks[j] str[i_:end]  i_, till
            return Nullable{T}(), i
        end
    end
    ## @show toks
    ( Nullable(tokf.f(result, i)), i_)
end

function TextParse.tryparsenext(t::TokenizerOp{:tokenize, T, F}, str, i, till, opts=TextParse.default_opts) where {T,F}
    r, i_ = tryparsenext(t.els.outer, str, i, till, opts)
    isnull(r) && return Nullable{T}(), i
    inner = tokenize(t.els.parser, get(r))
    if inner === nothing
        @warn "matched outer but not inner parser" get(r) t.els.parser
        ( Nullable{T}(), i )
    else
        ( Nullable{T}(inner), i_ )
    end
    ## instance(RT, (v,i) -> tokenize(result, v), outer)
end

function TextParse.tryparsenext(t::TokenizerOp{:rep, T, F}, str, i, till, opts=TextParse.default_opts) where {T,F}
    hist = Any[]
    i_=i
    repval, i__ = tryparsenext(t.els, str, i_, till)
    while !isnull(repval) && i_ != i__
        push!(hist, repval.value)
        i_=i__
        repval, i__ = tryparsenext(t.els, str, i_, till)
    end
    try
        ( Nullable(_convert(T,t.f(hist,i_))), i_)
    catch e
        @error "cannot convert to $T" e hist t
        error()
    end
end

function TextParse.tryparsenext(t::TokenizerOp{:rep1, T, F}, str, i, till, opts=TextParse.default_opts) where {T,F}
    ## @info "rep1" t.els
    hist = Any[]
    i_=i
    repval, i__ = tryparsenext(t.els, str, i_, till)
    while !isnull(repval) && i_ != i__
        push!(hist, repval.value)
        i_=i__
        repval, i__ = tryparsenext(t.els, str, i_, till)
    end
    if isempty(hist)
        Nullable{T}(), i
    else
        ( Nullable(_convert(T,t.f(hist,i_))), i_)
    end
end


default(x) = nothing
default(x::Regex) = ""
default(x::NamedToken) = x.name => missing



function TextParse.tryparsenext(t::TokenizerOp{:opt, T, F}, str, i, till, opts=TextParse.default_opts) where {T,F}
    r, i_ = tryparsenext(t.els.parser, str, i, till)
    if !isnull(r)        # @show typeof(r) r
        try
            r_ = _convert(T,t.f(r.value, i))
            return Nullable(r_), i_
        catch e
            @error "error transforming" e t t.f
            rethrow(e)
        end
    end
    ## @show default(t.els)
    r = t.els.default
    Nullable(r), i ## todo: t.default
end

function TextParse.tryparsenext(t::TokenizerOp{:alt, T, F}, str, i, till, opts=TextParse.default_opts) where {T,F}
    fromindex=1
    for j in fromindex:length(t.els)
        ## @info "alt" str[i:till] t.els[j]
        r, i_ = tryparsenext(t.els[j], str, i, till)
        if !isnull(r)            ## @show i_ seq_join(r.value)
            # @show t.f t.els[j] r.value
            ## @show match(Regex(regex_string(t.els[j])), str[i:end])
            try
                r_ = t.f(r.value, i)
                return Nullable(r_), i_
            catch e
                @error "cannot transform " t.f e r
                rethrow(e)
                return r,i
            end            
            ## return r, i_
        end
    end
    return Nullable{T}(), i
end

function TextParse.tryparsenext(t::TokenizerOp{:not, T, F}, str, i, till, opts=TextParse.default_opts) where {T,F}
    exclude, from = t.els
    ## @show str[i:till]
    r_,i_ = tryparsenext(from, str, i, till, opts)
    if !isnull(r_)
        re, ie = tryparsenext(exclude, str, i, till, opts)
        !isnull(re) && return Nullable{T}(), i
    end
    ## @show isnull(r_)
    r_, i_
end





export alternate
    
alternate(x::Vector, delim; kw...) = alternate(alt(x...), delim; kw...)
"""
optimized repeated alternations of `x``delim`, optionally starting/ending with `delim`. `delim` `is agg`ed as right borders. 
`delim` can be discarded in agg(result,missing,delim).

if `agg` is nothing, default is to aggregate delim after match is `result_type(delim) <: result_type(x)`, if not missing.
"""
function alternate(x::ParserTypes, delim::ParserTypes;
                   log=false,
                   agg = nothing,
                   kw...)
    T, S = result_type(typeof(x)), result_type(typeof(delim))
    af = if agg === nothing
        if S <: T
            ( r, xmatch, delimmatch ) -> begin
                xmatch !== missing && push!(r,xmatch)
                delimmatch !== missing && push!(r,delimmatch)
            end
        else
            ( r, xmatch, delimmatch ) -> begin
                xmatch !== missing && push!(r,xmatch)
            end 
        end
    else
        agg
    end
    
    function tf(v,i)
        ## @show v,i
        r = T[]
        if isempty(v[2])
            af(r,v[1],v[3])
        else
            ms = v[2]
            af(r,v[1],ms[1][1])
            for i in 2:lastindex(ms)
                af(r, ms[i-1][2],ms[i][1])
            end
            af(r, ms[end][2],v[3])
        end
        r
    end
    
    seq(Vector{T},
        opt(T, x; default=missing),
        rep(seq(delim, x)),
        opt(delim;default=missing)
        ; log=log,
        ## todo: factor out this transform condition!!
        transform = tf, kw...)
end


export rep_delim
rep_delim(x::TextParse.AbstractToken{T}, delim::TextParse.AbstractToken{S}; kw...) where {T,S} =
    rep_delim(promote_type(S,T), x, delim; kw...)
function rep_delim(
    T::Type, x, delim;
    log=false,repf=rep,
    transform=(v,i) -> v,
    transform_each=(v,i) -> v, kw...)
    x = parser(x)
    delim = parser(delim)
    function t(v,i)
        L = vcat(v...)
        transform(map(p -> transform_each(p,i),  L  ),i)
    end
    seq(Vector{T},
        opt(delim; default=T[], log=log),
        repf(Vector{T},
             seq(x, delim; log=log); log=log,
             transform = (v,i) -> vcat([ [x...] for x in v ]...)),
        opt(x; default=T[], log=log)
        ; log=log,
        ## todo: factor out this transform condition!!
        transform = (t)
        , kw...)
end


export rep_delim_par
function rep_delim_par(x, delim; repf=rep, transform=(v,i) -> v, transform_each=v -> v, kw...)
    x = parser(x)
    delim = parser(delim)
    T = result_type(typeof(x))
    D = result_type(typeof(delim))
    seq(Vector{T},
        opt(Vector{D}, delim; transform = (v,i) -> D[v]),
        repf(seq(T, x, delim; 
                 transform = (v, i) -> v[1]);
             transform=(v,i) -> v),
        opt(Vector{T}, x; transform = (v,i) -> T[v])
        ; 
        ## todo: factor out this transform condition!!
        transform = (v,i)  -> transform(
            map(p -> transform_each(p),
                vcat(v[2:end]...)),i)
        , kw...)
end

## export tokenizer_regex
##function tokenizer_regex()
##    re = (
lf          = r"\n"
newline     = r"\r?\n"
whitespace  = r"[ \t]+"
whitenewline = r"[ \t]*\r?\n"
quotes      = r"[\"'`]"
inline      = r"[^\n\r]*"
indentation = r"[ \t]*"
content_characters = r"[^\t\r\n]+"
number      = r"[0-9]+"  ## TODO alt(...) csv
letters     = r"[A-Za-z*-]*"
# 
parenthesisP(open,close) = seq(String,
    open, r"[^][{}()]*", close;
    transform=(v,i) -> join(v))
delimiter   = r"[-, _/\.;:*]"
word        = r"[^\[\]\(\){<>},*;:=\| \t_/\.\n\r\"'`⁰¹²³⁴⁵⁶⁷⁸⁹]+"
footnote    = r"^[⁰¹²³⁴⁵⁶⁷⁸⁹]+"
enum_label = r"(?:[0-9]{1,3}|[ivx]{1,6}|[[:alpha:]])[\.\)]"
wdelim = r"^[ \t\r\n]+"



export emptyline
emptyline = r"^[ \t]*\r?\n"

extension   = r"\.[[:alnum:]~#]+"

email_regexp = r"[-+_.~a-zA-Z][-+_.~:a-zA-Z0-9]*@[-.a-zA-Z0-9]+"
author_email = seq(NamedTuple,
                   :name => opt(instance(String,r"^[^<]+")),
                   r" <",
                   :email => email_regexp,
                   r">"; combine=true)


pad(x) = seq(opt(whitespace), x, opt(whitespace), transform = v->v[2])

### from tokens????
## match(r::Regex, x::TokenTuple) =  match(r, show(x))
# endswith(x::TokenTuple, suffix::AbstractString) =  endswith(x[end].value, suffix)


struct MemoTreeChildren{P}
    visited::Dict
    child::P
    descend::Bool
end





include("show.jl")
include("tokens.jl")

end # module
