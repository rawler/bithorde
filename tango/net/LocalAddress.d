/*******************************************************************************

        copyright:      Copyright (c) 2009 Lukas Pinkowski. All rights reserved

        license:        BSD style: $(LICENSE)

        version:        Initial release: Aug 2009      
        
        author:         Lukas Pinkowski

*******************************************************************************/

module tango.net.LocalAddress;

private import tango.net.device.Berkeley;

/*******************************************************************************


*******************************************************************************/

public class LocalAddress : Address
{
		struct sockaddr_un
		{
			align(1):
				ushort sun_family = AddressFamily.UNIX;
				char[108] sun_path;
		}
		
				
		protected
		{
				sockaddr_un sun;
				char[] _path;
				int _pathLength;
		}

		/***********************************************************************

			-path- path to a unix domain socket (which is a filename)

		***********************************************************************/
		this(char[] path)
		{
				assert(path.length < 108);
				
				sun.sun_path[0 .. path.length] = path[];
				sun.sun_path[path.length .. $] = 0;
				
				_pathLength = path.length;
				_path = sun.sun_path[0 .. path.length];
		}

		/***********************************************************************



		***********************************************************************/
		sockaddr* name() 
		{ 
				return cast(sockaddr*)&sun; 
		}
		
		/***********************************************************************



		***********************************************************************/
		int nameLen() 
		{ 
				return _pathLength + ushort.sizeof; 
		}
		
		/***********************************************************************



		***********************************************************************/
		AddressFamily addressFamily() 
		{ 
				return AddressFamily.UNIX; 
		}
		
		/***********************************************************************



		***********************************************************************/
		char[] toString()
		{
				if(isAbstract)
					return "unix:abstract=" ~ _path[1..$];
				else
					return "unix:path=" ~ _path;
		}
		
		/***********************************************************************



		***********************************************************************/
		char[] path()
		{
			return _path;
		}
		
		/***********************************************************************



		***********************************************************************/
		bool isAbstract()
		{
			return _path[0] == 0;
		}
}

