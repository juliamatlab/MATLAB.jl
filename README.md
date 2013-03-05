## MATLAB.jl

A package to support calling MATLAB functions and manipulating MATLAB arrays in Julia.

[Julia](http://julialang.org) is a technical computing language, which relies on LLVM to achieve efficiency comparable to C. As a young language, many useful functions are still lacking (*e.g.* 3D plot). This package allows users to call MATLAB functions from within Julia, thus making it easier to use the sheer amount of toolboxes available in MATLAB.

### Overview

Generally, this package is comprised of two aspects:

* Creating and manipulating mxArrays (the data structure that MATLAB used to represent arrays and other kinds of data)

* Communicating with MATLAB engine sessions

### Installation

The procedure to setup this package consists of three steps. 

##### Linux

1. Make sure ``matlab`` is in executable path. 

2. Make sure ``csh`` is installed. (Note: MATLAB for Linux relies on ``csh`` to open an engine session.) 
	
	To install ``csh`` in Debian/Ubuntu/Linux Mint, you may type in the following command in terminal:
	
	```
	sudo apt-get install csh
	```

3. Clone this package from the GitHub repo to your Julia package directory, as

	```
	cd <your/julia/package/path>
	git clone https://github.com/lindahua/MATLAB.jl.git MATLAB
	```

##### Mac OS X

1. Make sure ``matlab`` is in executable path. 

2. Export an environment variable ``MATLAB_HOME``. For example, if you are using MATLAB R2012b, you may add the following command to ``.profile``:
	
	```
	export MATLAB_HOME=/Applications/MATLAB_R2012b.app
	```

3. Clone this package from the GitHub repo to your Julia package directory, as



### MxArray class

An instance of ``MxArray`` encapsulates a MATLAB variable. This package provides a series of functions to manipulate such instances.

#### Create MATLAB variables in Julia

One can use the function ``mxarray`` to create MATLAB variables (of type ``MxArray``), as follows

```julia
mxarray(Float64, n)   # creates an n-by-1 MATLAB zero array of double valued type
mxarray(Int32, m, n)  # creates an m-by-n MATLAB zero array of int32 valued type 
mxarray(Bool, m, n)   # creates a MATLAB logical array of size m-by-n

mxarray(Float64, (n1, n2, n3))  # creates a MATLAB array of size n1-by-n2-by-n3
```

You may also convert a Julia variable to MATLAB variable

```julia
a = rand(m, n)
x = mxarray(a)      # converts v to a MATLAB array

x = mxscalar(1.2)   # creates a MATLAB scalar of value 1.2
```

MATLAB has its own memory management mechanism, and a MATLAB array is not able to use Julia's memory. Hence, the conversion from a Julia array to a MATLAB array involves deep-copy.

When you finish using a MATLAB variable, you may call ``delete`` to free the memory. But this is optional, it will be deleted when reclaimed by the garbage collector.

```julia
delete(x)
```

*Note:* if you put a MATLAB variable ``x`` to MATLAB engine session, then the MATLAB engine will take over the management of its life cylce, and you don't have to delete it explicitly.


#### Access MATLAB variables

You may access attributes and data of a MATLAB variable through the functions provided by this package.

```julia
 # suppose x is of type MxArray
nrows(x)    # returns number of rows in x
ncols(x)    # returns number of columns in x 
nelems(x)   # returns number of elements in x
ndims(x)    # returns number of dimensions in x
size(x)     # returns the size of x as a tuple
size(x, d)  # returns the size of x along a specific dimension

eltype(x)   # returns element type of x (in Julia Type)
elsize(x)   # return number of bytes per element

data_ptr(x)   # returns pointer to data (in Ptr{T}), where T is eltype(x)
```

Many more to be added soon. (We aim at full coverage of mex C interface)

#### Convert MATLAB variables to Julia

```julia
a = jarray(x)   # converts x to a Julia array
a = jvector(x)  # converts x to a Julia vector (1D array) when x is a vector
a = jscalar(x)  # converts x to a Julia scalar
```

*Note:* Unlike the conversion from Julia to MATLAB, ``a`` is actually a view of ``x`` (created through ``pointer_to_array``), and does not own the memory. 


### Use MATLAB Engine

#### Basic Use

To evaluate expressions in MATLAB, one may open a MATLAB engine session and communicate with it.

Below is a simple example that illustrates how one can use MATLAB from within Julia:

```julia
using MATLAB

restart_default_msession()   # Open a default MATLAB session

x = linspace(-10., 10., 500)

@mput x                  # put x to MATLAB's workspace
@matlab plot(x, sin(x))  # evaluate a MATLAB function

close_default_msession()    # close the default session (optional)
```

You can put multiple variable and evaluate multiple statement by calling ``@mput`` and ``@matlab`` once:
```julia

x = linspace(-10., 10., 500)
y = linspace(2., 3., 500)

@mput x y
@matlab begin
    u = x + y
	v = x - y
end

u = jarray(get_mvariable(:u))  # retrieve the result from MATLAB session
v = jarray(get_mvariable(:v))

```

*Note:* There can be multiple (reasonable) ways to convert a MATLAB variable to Julia array. For example, MATLAB represents a scalar using a 1-by-1 matrix. Here we have two choice in terms of converting such a matrix back to Julia: (1) convert to a scalar number, or (2) convert to a matrix of size 1-by-1.

Here, ``get_mvariable`` returns an instance of ``MxArray``, and the user can make his own choice by calling ``jarray``, ``jvector``, or ``jscalar`` to convert it to a Julia variable.

#### Caveats of @matlab

Note that some MATLAB expressions is not a valid Julia expression. This package provides some ways to work around this in the ``@matlab`` macro:

```julia
 # MATLAB uses single-quote for strings, while Julia uses double-quote. 
@matlab sprintf("%d", 10)   # ==> MATLAB: sprintf('%d', 10)

 # MATLAB does not allow [x, y] on the left hand side
x = linspace(-5., 5. 100)
y = x
@mput x y
@matlab begin
    (xx, yy) = meshgrid(x, y)  # ==> MATLAB: [xx, yy] = meshgrid(x, y)
	mesh(xx, yy, xx.^2 + yy.^2)
end
```

While we try to cover most MATLAB statements, some valid MATLAB statements remain unsupported by ``@matlab``. For this case, one may always call the ``eval_string`` function, as follows

```julia
eval_string("[u, v] = myfun(x, y);")
```


#### Advanced use of MATLAB Engines

This package provides a series of functions for users to control the communication with MATLAB sessions.

Here is an example:

```julia
s1 = MSession()    # creates a MATLAB session
s2 = MSession(0)   # creates a MATLAB session without recording output

x = rand(3, 4)
put_variable(s1, :x, x)  # put x to session s1

y = rand(2, 3)
put_variable(s2, :y, y)  # put y to session s2

eval_string(s1, "r = sin(x)")  # evaluate sin(x) in session s1
eval_string(s2, "r = sin(y)")  # evaluate sin(y) in session s2

r1_mx = get_mvariable(s1, :r)  # get r from s1
r2_mx = get_mvariable(s2, :r)  # get r from s2

r1 = jarray(r1_mx)
r2 = jarray(r2_mx)

...  # do other stuff on r1 and r2

close(s1)  # close session s1
close(s2)  # close session s2
```

