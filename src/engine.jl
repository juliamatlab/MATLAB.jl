# operation on MATLAB engine sessions

###########################################################
#
#   Session open & close
#
###########################################################
const default_startflag = "-nodisplay -nosplash -nodesktop" # no additional flags
const default_matlabcmd = matlab_cmd * " -nodisplay -nosplash -nodesktop"
# pass matlab flags directly or as a Vector of flags, i.e. "-a" or ["-a", "-b", "-c"]
startcmd(flag::AbstractString=default_startflag) =
    isempty(flag) ? default_matlabcmd : default_matlabcmd * " " * flag
startcmd(flags::AbstractVector{<:AbstractString}) =
    isempty(flags) ? default_matlabcmd : default_matlabcmd * " " * join(flags, " ")

# 64 K buffer should be sufficient to store the output text in most cases
const default_output_buffer_size = 64 * 1024

const windows_regserver_warning = """
Failed to start MATLAB engine. If you have/had multiple versions of MATLAB installed, this can happen if you 
tried to start a different version of MATLAB in Julia compared to which MATLAB server is registered in Windows.

Steps to resolve this:

1. Register a specific MATLAB version manually as a server, open a MATLAB window as a user with administrator privileges. 
In MATLAB, enter the command `!matlab -regserver`. Then close the MATLAB window. More details:
https://de.mathworks.com/help/matlab/matlab_external/registering-matlab-software-as-a-com-server.html

2. Ensure that the MATLAB.jl package is using the same MATLAB version that was registered in step 1. See the instructions on GitHub
on how to change the version that MATLAB.jl uses:
https://github.com/JuliaInterop/MATLAB.jl?tab=readme-ov-file#changing-matlab-version
"""

mutable struct MSession
    ptr::Ptr{Cvoid}
    buffer::Vector{UInt8}
    bufptr::Ptr{UInt8}
    check_exceptions::Bool

    function MSession(
        bufsize::Integer=default_output_buffer_size;
        flags=default_startflag,
        check_exceptions::Bool=true,
    )
        if Sys.iswindows()
            assign_persistent_msession()
        end
        ep = ccall(eng_open[], Ptr{Cvoid}, (Ptr{UInt8},), startcmd(flags))
        if ep == C_NULL
            @warn(
                "Confirm MATLAB is installed and discoverable.",
                matlab_libpath,
                maxlog = 1
            )
            if Sys.iswindows()
                @warn(windows_regserver_warning, maxlog = 1)
            elseif Sys.islinux()
                @warn(
                    "Ensure `csh` is installed; this may require running `sudo apt-get install csh`.",
                    maxlog = 1
                )
            end
            throw(MEngineError("failed to open MATLAB engine session"))
        end
        if Sys.iswindows()
            # hide the MATLAB command window on Windows and change to current directory
            ccall(eng_set_visible[], Cint, (Ptr{Cvoid}, Cint), ep, 0)
            ccall(eng_eval_string[], Cint, (Ptr{Cvoid}, Ptr{UInt8}),
                ep, "try cd('$(escape_string(pwd()))'); end")
        end
        buf = Vector{UInt8}(undef, bufsize)
        if bufsize > 0
            bufptr = pointer(buf)
            ccall(eng_output_buffer[], Cint, (Ptr{Cvoid}, Ptr{UInt8}, Cint),
                ep, bufptr, bufsize)
        else
            bufptr = convert(Ptr{UInt8}, C_NULL)
        end

        self = new(ep, buf, bufptr, check_exceptions)
        finalizer(release, self)
        return self
    end
end

function unsafe_convert(::Type{Ptr{Cvoid}}, m::MSession)
    ptr = m.ptr
    ptr == C_NULL && throw(UndefRefError())
    return ptr
end

function release(session::MSession)
    ptr = session.ptr
    if ptr != C_NULL
        ccall(eng_close[], Cint, (Ptr{Cvoid},), ptr)
    end
    session.ptr = C_NULL
    return nothing
end

function close(session::MSession)
    # close a MATLAB Engine session
    ret = ccall(eng_close[], Cint, (Ptr{Cvoid},), session)
    ret != 0 && throw(MEngineError("failed to close MATLAB engine session (err = $ret)"))
    session.ptr = C_NULL
    return nothing
end

has_exception_check_enabled(session::MSession=get_default_msession()) =
    session.check_exceptions
disable_exception_check!(session::MSession=get_default_msession()) =
    (session.check_exceptions = false; nothing)
enable_exception_check!(session::MSession=get_default_msession()) =
    (session.check_exceptions = true; nothing)

# default session

const default_msession_ref = Ref{MSession}()

# this function will start an MSession if default_msession_ref is undefined or if the
# MSession has been closed so that the engine ptr is void
function get_default_msession()
    if !isassigned(default_msession_ref) || default_msession_ref[].ptr == C_NULL
        default_msession_ref[] = MSession()
    end
    return default_msession_ref[]
end

function restart_default_msession(bufsize::Integer=default_output_buffer_size)
    close_default_msession()
    default_msession_ref[] = MSession(bufsize)
    return nothing
end

function close_default_msession()
    if isassigned(default_msession_ref) && default_msession_ref[].ptr !== C_NULL
        close(default_msession_ref[])
    end
    return nothing
end

if Sys.iswindows()
    function show_msession(m::MSession=get_default_msession())
        ret = ccall(eng_set_visible[], Cint, (Ptr{Cvoid}, Cint), m, 1)
        ret != 0 && throw(MEngineError("failed to show MATLAB engine session (err = $ret)"))
        return nothing
    end

    function hide_msession(m::MSession=get_default_msession())
        ret = ccall(eng_set_visible[], Cint, (Ptr{Cvoid}, Cint), m, 0)
        ret != 0 && throw(MEngineError("failed to hide MATLAB engine session (err = $ret)"))
        return nothing
    end

    function get_msession_visiblity(m::MSession=get_default_msession())
        vis = Ref{Cint}(true)
        ccall(eng_get_visible[], Int, (Ptr{Cvoid}, Ptr{Cint}), m, vis)
        return vis[] == 1 ? true : false
    end
end

###########################################################
#
#   communication with MATLAB session
#
###########################################################

function _eval_string(session::MSession, stmt::String)
    # evaluate a MATLAB statement in a given MATLAB session
    ret = ccall(eng_eval_string[], Cint, (Ptr{Cvoid}, Ptr{UInt8}), session, stmt)
    ret != 0 && throw(MEngineError("invalid engine session (err = $ret)"))

    bufptr = session.bufptr
    if bufptr != C_NULL
        bs = unsafe_string(bufptr)
        if ~isempty(bs)
            print(bs)
        end
    end
    return nothing
end

function eval_string(session::MSession, stmt::String)
    _eval_string(session, stmt)
    if session.check_exceptions
        check_and_clear_last_exception(session)
    end
end

eval_string(stmt::String) = eval_string(get_default_msession(), stmt)

function put_variable(session::MSession, name::Symbol, v::MxArray)
    # put a variable into a MATLAB engine session
    ret = ccall(
        eng_put_variable[],
        Cint,
        (Ptr{Cvoid}, Ptr{UInt8}, Ptr{Cvoid}),
        session,
        string(name),
        v,
    )
    ret != 0 && throw(
        MEngineError("failed to put variable $(name) into MATLAB session (err = $ret)"),
    )
    return nothing
end

put_variable(session::MSession, name::Symbol, v) = put_variable(session, name, mxarray(v))

put_variable(name::Symbol, v) = put_variable(get_default_msession(), name, v)

function get_mvariable(session::MSession, name::Symbol)
    pv = ccall(
        eng_get_variable[],
        Ptr{Cvoid},
        (Ptr{Cvoid}, Ptr{UInt8}),
        session,
        string(name),
    )
    pv == C_NULL &&
        throw(MEngineError("failed to get variable $(name) from MATLAB session"))
    return MxArray(pv)
end

get_mvariable(name::Symbol) = get_mvariable(get_default_msession(), name)

get_variable(name::Symbol) = jvalue(get_mvariable(name))
get_variable(name::Symbol, kind) = jvalue(get_mvariable(name), kind)

"""
    check_and_clear_last_exception(session::MSession)

Checks if an exception has been thrown in the MATLAB session by checking the `MException.last` variable.
If it is not empty, it throws a `MatlabException` with the message and identifier of the last exception.
In any case, it clears the `MException.last` variable.
"""
function check_and_clear_last_exception(session::MSession)
    exception_check_code = """
    matlab_exception_jl_message = MException.last.message; 
    matlab_exception_jl_identifier = MException.last.identifier; 
    MException.last('reset');
    """
    _eval_string(session, exception_check_code)
    message = jvalue(get_mvariable(session, :matlab_exception_jl_message))
    identifier = jvalue(get_mvariable(session, :matlab_exception_jl_identifier))

    if !isempty(identifier)
        throw(MatlabException(identifier, message))
    end

    _eval_string(
        session,
        "clear matlab_exception_jl_message matlab_exception_jl_identifier;",
    )
end

###########################################################
#
#   macro to simplify syntax
#
###########################################################

function _mput_multi(vs::Symbol...)
    nv = length(vs)
    if nv == 1
        v = vs[1]
        :(MATLAB.put_variable($(Meta.quot(v)), $(v)))
    else
        stmts = Vector{Expr}(undef, nv)
        for i = 1:nv
            v = vs[i]
            stmts[i] = :(MATLAB.put_variable($(Meta.quot(v)), $(v)))
        end
        Expr(:block, stmts...)
    end
end

macro mput(vs...)
    esc(_mput_multi(vs...))
end

function make_getvar_statement(v::Symbol)
    :($(v) = MATLAB.get_variable($(Meta.quot(v))))
end

function make_getvar_statement(ex::Expr)
    if !(ex.head == :(::))
        error("Invalid expression for @mget.")
    end
    v::Symbol = ex.args[1]
    k::Symbol = ex.args[2]

    :($(v) = MATLAB.get_variable($(Meta.quot(v)), $(k)))
end

function _mget_multi(vs::Union{Symbol,Expr}...)
    nv = length(vs)
    if nv == 1
        make_getvar_statement(vs[1])
    else
        stmts = Vector{Expr}(undef, nv)
        for i = 1:nv
            stmts[i] = make_getvar_statement(vs[i])
        end
        Expr(:block, stmts...)
    end
end

macro mget(vs...)
    esc(_mget_multi(vs...))
end

###########################################################
#
#   mxcall
#
###########################################################

# MATLAB does not allow underscore as prefix of a variable name
_gen_marg_name(mfun::Symbol, prefix::String, i::Int) = "jx_$(mfun)_arg_$(prefix)_$(i)"

function mxcall(session::MSession, mfun::Symbol, nout::Integer, in_args...)
    nin = length(in_args)

    # generate temporary variable names

    in_arg_names = Vector{String}(undef, nin)
    out_arg_names = Vector{String}(undef, nout)

    for i = 1:nin
        in_arg_names[i] = _gen_marg_name(mfun, "in", i)
    end

    for i = 1:nout
        out_arg_names[i] = _gen_marg_name(mfun, "out", i)
    end

    # generate MATLAB statement

    buf = IOBuffer()
    if nout > 0
        if nout > 1
            print(buf, "[")
        end
        join(buf, out_arg_names, ", ")
        if nout > 1
            print(buf, "]")
        end
        print(buf, " = ")
    end

    print(buf, string(mfun))
    print(buf, "(")
    if nin > 0
        join(buf, in_arg_names, ", ")
    end
    print(buf, ");")

    stmt = String(take!(buf))

    # put variables to MATLAB

    for i = 1:nin
        put_variable(session, Symbol(in_arg_names[i]), in_args[i])
    end

    # execute MATLAB statement

    eval_string(session, stmt)

    # get results from MATLAB

    ret = if nout == 1
        jvalue(get_mvariable(session, Symbol(out_arg_names[1])))
    elseif nout >= 2
        results = Vector{Any}(undef, nout)
        for i = 1:nout
            results[i] = jvalue(get_mvariable(session, Symbol(out_arg_names[i])))
        end
        tuple(results...)
    else
        nothing
    end

    # clear temporaries from MATLAB workspace

    for i = 1:nin
        eval_string(session, string("clear ", in_arg_names[i], ";"))
    end

    for i = 1:nout
        eval_string(session, string("clear ", out_arg_names[i], ";"))
    end

    return ret
end

mxcall(mfun::Symbol, nout::Integer, in_args...) =
    mxcall(get_default_msession(), mfun, nout, in_args...)
