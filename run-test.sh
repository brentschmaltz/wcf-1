#!/usr/bin/env bash

wait_on_pids()
{
  # Wait on the last processes
  for job in $1
  do
    wait $job
    if [ "$?" -ne 0 ]
    then
      TestsFailed=$(($TestsFailed+1))
    fi
  done
}

usage()
{
    echo "Runs .NET Wcf tests on FreeBSD, Linux or OSX"
    echo "usage: run-test [options]"
    echo
    echo "Input sources:"
    echo "    --coreclr-bins <location>         Location of root of the binaries directory"
    echo "                                      containing the FreeBSD, Linux or OSX coreclr build"
    echo "                                      default: <repo_root>/bin/Product/<OS>.x64.<Configuration>"
    echo "    --mscorlib-bins <location>        Location of the root binaries directory containing"
    echo "                                      the FreeBSD, Linux or OSX mscorlib.dll"
    echo "                                      default: <repo_root>/bin/Product/<OS>.x64.<Configuration>"
    echo "    --corefx-tests <location>         Location of the root binaries location containing"
    echo "                                      the tests to run"
    echo "                                      default: <repo_root>/bin/tests/<OS>.AnyCPU.<Configuration>"
    echo "    --corefx-native-bins <location>   Location of the FreeBSD, Linux or OSX native corefx binaries"
    echo "                                      default: <repo_root>/bin/<OS>.x64.<Configuration>"
    echo "    --wcf-bins <location>             Location of the linux/mac WCF binaries"
    echo "                                      default: <repo_root>/bin/<OS>.AnyCPU.<Configuration>"
    echo "    --wcf-tests <location>            Location of the root binaries location containing"
    echo "                                      the windows WCF tests"
    echo "    --bridge-host <machineName>       Machine hosting the Bridge for multi-machine tests"
    echo
    echo "    --xunit-args <xunit args>         Additional args to pass to xunit"
    echo
    echo "Flavor/OS options:"
    echo "    --configuration <config>          Configuration to run (Debug/Release)"
    echo "                                      default: Debug"
    echo "    --os <os>                         OS to run (FreeBSD, Linux or OSX)"
    echo "                                      default: detect current OS"
    echo
    echo "Execution options:"
    echo "    --restrict-proj <regex>       Run test projects that match regex"
    echo "                                  default: .* (all projects)"
    echo
    exit 1
}

ProjectRoot="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Location parameters
# OS/Configuration defaults
Configuration="Debug"
OSName=$(uname -s)
case $OSName in
    Darwin)
        OS=OSX
        ;;

    FreeBSD)
        OS=FreeBSD
        ;;

    Linux)
        OS=Linux
        ;;

    *)
        echo "Unsupported OS $OSName detected, configuring as if for Linux"
        OS=Linux
        ;;
esac
# Misc defaults
TestSelection=".*"
TestsFailed=0
BridgeHost=""
XunitArgs="-notrait category=failing -notrait category=OuterLoop"
OverlayDir="$ProjectRoot/bin/tests/$OS.AnyCPU.$Configuration/TestOverlay/"

create_test_overlay()
{
  local mscorlibLocation="$MscorlibBins/mscorlib.dll"

  # Make the overlay

  rm -rf $OverlayDir
  mkdir -p $OverlayDir
  
  local LowerConfiguration="$(echo $Configuration | awk '{print tolower($0)}')"

  # First the temporary test host binaries
  local packageLibDir="$packageDir/lib"
  local mscorlibLocation="$MscorlibBins/mscorlib.dll"
  
  # First copy the binaries from the linux build of WCF
  if [ ! -d $WcfBins ]
  then
	echo "WCF binaries not found at $WcfBins"
	exit 1
  fi
  find $WcfBins -name '*.dll' -and -not -name "*Test*" -exec cp '{}' "$OverlayDir" ";"

  if [ ! -d $packageLibDir ]
  then
	echo "Package not laid out as expected"
	exit 1
  fi
  cp $packageLibDir/* $OverlayDir
  
  # Copy some binaries from the linux build of corefx
  if [ ! -d $CoreFxBins ]
  then
	echo "Corefx binaries not found at $CoreFxBins"
	exit 1
  fi
  
# Currently need to overwrite some packaged binaries from CoreFx
# See issue https://github.com/dotnet/wcf/issues/442
# echo "Copying selected CoreFxBins..."

  find $CoreFxBins -name '*.dll' -and -name "*System.Private.Networking*" -and -not -wholename "*Test*" -and -not -wholename "*/ToolRuntime/*" -and -not -wholename "*/RemoteExecutorConsoleApp/*"  -exec cp '{}' "$OverlayDir" ";"
  find $CoreFxBins -name '*.dll' -and -name "*System.Net.*" -and -not -wholename "*Test*" -and -not -wholename "*/ToolRuntime/*" -and -not -wholename "*/RemoteExecutorConsoleApp/*"  -exec cp '{}' "$OverlayDir" ";"

  # Copy the CoreCLR native binaries
  if [ ! -d $CoreClrBins ]
  then
	echo "Coreclr $OS binaries not found at $CoreClrBins"
	exit 1
  fi
  cp -r $CoreClrBins/* $OverlayDir
  
  # Then the mscorlib from the upstream build.
  # TODO When the mscorlib flavors get properly changed then
  if [ ! -f $mscorlibLocation ]
  then
	echo "Mscorlib not found at $mscorlibLocation"
	exit 1
  fi
  cp -r $mscorlibLocation $OverlayDir

  # Then the native CoreFX binaries
  if [ ! -d $CoreFxNativeBins ]
  then
	echo "Corefx native binaries should be built (use build.sh native in root)"
	exit 1
  fi
  cp $CoreFxNativeBins/* $OverlayDir

  # Remove from the OverlayDir any ServiceModel assemblies.
  # The versions in the ServiceModel tests folders are the ones we want.
  rm -f $OverlayDir/System.Private.ServiceModel.dll
  rm -f $OverlayDir/System.ServiceModel.*.dll
}

copy_test_overlay()
{
  testDir=$1
  cp -r $OverlayDir/* $testDir/
}


# $1 is the name of the test project
runtest()
{
  testProject=$1

  # Check here to see whether we should run this project

  if grep "UnsupportedPlatforms.*$OS.*" $1 > /dev/null
  then
    echo "Test project file $1 indicates this test is not supported on $OS, skipping"
    exit 0
  fi
  
  # Check for project restrictions
  
  if [[ ! $testProject =~ $TestSelection ]]; then
    echo "Skipping $testProject"
    exit 0
  fi

  # Grab the directory name that would correspond to this test

  lowerOS="$(echo $OS | awk '{print tolower($0)}')"
  fileName="${file##*/}"
  fileNameWithoutExtension="${fileName%.*}"
  testDllName="$fileNameWithoutExtension.dll"
  xunitOSCategory="non$lowerOS"
  xunitOSCategory+="tests"

  dirName="$WcfTests/$fileNameWithoutExtension/dnxcore50"

  if [ ! -d "$dirName" ] || [ ! -f "$dirName/$testDllName" ]
  then
    echo "Did not find corresponding test dll for $testProject at $dirName/$testDllName"
    exit 1
  fi

  copy_test_overlay $dirName

  pushd $dirName > /dev/null

  # Remove the mscorlib native image, since our current test layout build process
  # uses a windows runtime and so we include the windows native image for mscorlib
  if [ -e mscorlib.ni.dll ]
  then
    rm mscorlib.ni.dll
  fi
  
  chmod +x ./corerun
  
  # Invoke xunit

  echo
  echo "Running tests in $dirName"
  echo "./corerun xunit.console.netcore.exe $testDllName -xml testResults.xml $XunitArgs -notrait category=$xunitOSCategory"
  echo
  ./corerun xunit.console.netcore.exe $testDllName -xml testResults.xml $XunitArgs -notrait category=$xunitOSCategory
  exitCode=$?
  
  
  if [ $exitCode -ne 0 ]
  then
      echo "One or more tests failed while running tests from '$fileNameWithoutExtension'.  Exit code $exitCode."
  fi
  
  popd > /dev/null
  exit $exitCode
}

# Parse arguments

while [[ $# > 0 ]]
do
    opt="$1"
    case $opt in
        -h|--help)
        usage
        ;;
        --coreclr-bins)
        CoreClrBins=$2
        ;;
        --mscorlib-bins)
        MscorlibBins=$2
        ;;
        --corefx-bins)
        CoreFxBins=$2
        ;;
        --corefx-native-bins)
        CoreFxNativeBins=$2
        ;;
        --wcf-tests)
        WcfTests=$2
        ;;
        --wcf-bins)
        WcfBins=$2
        ;;
        --bridge-host)
        BridgeHost=$2
        export BridgeHost
        ;;
        --xunit-args)
        XunitArgs=$2
        ;;
        --restrict-proj)
        TestSelection=$2
        ;;
        --configuration)
        Configuration=$2
        ;;
        --os)
        OS=$2
        ;;        
        *)
        ;;
    esac
    shift
done

# Compute paths to the binaries if they haven't already been computed

if [ "$CoreClrBins" == "" ]
then
    CoreClrBins="$ProjectRoot/bin/Product/$OS.x64.$Configuration"
fi

if [ "$MscorlibBins" == "" ]
then
    MscorlibBins="$ProjectRoot/bin/Product/$OS.x64.$Configuration"
fi

if [ "$CoreFxBins" == "" ]
then
    CoreFxBins="$ProjectRoot/bin/$OS.AnyCPU.$Configuration"
fi

if [ "$CoreFxNativeBins" == "" ]
then
    CoreFxNativeBins="$ProjectRoot/bin/$OS.x64.$Configuration/Native"
fi

if [ "$WcfTests" == "" ]
then
    WcfTests="$ProjectRoot/bin/tests/Windows_NT.AnyCPU.$Configuration"
fi

if [ "$WcfBins" == "" ]
then
    CoreFxBins="$ProjectRoot/bin/$OS.AnyCPU.$Configuration"
fi

# Check parameters up front for valid values:

if [ ! "$Configuration" == "Debug" ] && [ ! "$Configuration" == "Release" ]
then
    echo "Configuration should be Debug or Release"
    exit 1
fi

if [ ! "$OS" == "FreeBSD" ] && [ ! "$OS" == "Linux" ] && [ ! "$OS" == "OSX" ]
then
    echo "OS should be FreeBSD, Linux or OSX"
    exit 1
fi

if [ "$CoreClrObjs" == "" ]
then
    CoreClrObjs="$ProjectRoot/bin/obj/$OS.x64.$Configuration"
fi

if [ "$XunitArgs" != *"OuterLoop"* ]
then
    echo "OuterLoop tests will be run using the Bridge at $BridgeHost"
fi

create_test_overlay

# Walk the directory tree rooted at src bin/tests/$OS.AnyCPU.$Configuration/

TestsFailed=0
numberOfProcesses=0
maxProcesses=$(($(getconf _NPROCESSORS_ONLN)+1))
TestProjects=($(find . -regex ".*/src/.*/tests/.*\.Tests\.csproj"))
for file in ${TestProjects[@]}
do
  runtest $file &
  pids="$pids $!"
  numberOfProcesses=$(($numberOfProcesses+1))
  if [ "$numberOfProcesses" -ge $maxProcesses ]; then
    wait_on_pids "$pids"
    numberOfProcesses=0
    pids=""
  fi
done

# Wait on the last processes
wait_on_pids "$pids"

if [ "$TestsFailed" -gt 0 ]
then
    echo "$TestsFailed test(s) failed"
else
    echo "All tests passed."
fi

exit $TestsFailed


