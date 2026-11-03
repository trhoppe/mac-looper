#!/usr/bin/env python3
"""Generate native Mac/iPad app targets sharing the local Swift packages and UI sources."""
from pathlib import Path
import hashlib, json
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'MacLooper.xcodeproj'
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(key_name, isa, **fields):
    key=uid(key_name);objects[key]={'isa':isa,**fields};return key
def encode(v, level=0):
    if isinstance(v,dict): return '{\n'+''.join('\t'*(level+1)+json.dumps(k)+ ' = '+encode(x,level+1)+';\n' for k,x in v.items())+'\t'*level+'}'
    if isinstance(v,list): return '(\n'+''.join('\t'*(level+1)+encode(x,level+1)+',\n' for x in v)+'\t'*level+')'
    return json.dumps(str(v))
project=uid('project');root=uid('root')
products=[];source_refs=[];resource_refs=[]
sources=sorted((ROOT/'Sources/MacLooper').glob('*.swift'))
for p in sources:
    source_refs.append(obj(str(p.relative_to(ROOT)),'PBXFileReference',lastKnownFileType='sourcecode.swift',path=str(p.relative_to(ROOT)),sourceTree='SOURCE_ROOT'))
asset=obj('assetcatalog','PBXFileReference',lastKnownFileType='folder.assetcatalog',path='Assets/Shared.xcassets',sourceTree='SOURCE_ROOT');resource_refs.append(asset)
package=obj('package','XCLocalSwiftPackageReference',relativePath='.')
remote_package=obj('remote-package','XCLocalSwiftPackageReference',relativePath='Packages/AM4RemoteKit')
base={'SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SWIFT_STRICT_CONCURRENCY':'minimal','ENABLE_USER_SCRIPT_SANDBOXING':'YES','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'}
def configs(name,settings):
    refs=[]
    for mode in ['Debug','Release']:
        v={**base,**settings,'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym'}
        if mode=='Debug': v['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) DEBUG';v['ENABLE_TESTABILITY']='YES';v['ONLY_ACTIVE_ARCH']='YES'
        refs.append(obj(name+mode,'XCBuildConfiguration',buildSettings=v,name=mode))
    return obj(name+'configs','XCConfigurationList',buildConfigurations=refs,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')

def package_dependencies(name):
    deps=[];build=[]
    for product in ['JamCore','LooperCore','LooperAudioUnit','AM4RemoteKit']:
        dep=obj(name+product+'dep','XCSwiftPackageProductDependency',package=remote_package if product == 'AM4RemoteKit' else package,productName=product);deps.append(dep)
        build.append(obj(name+product+'link','PBXBuildFile',productRef=dep))
    return deps,build

def app(name, platform):
    ipad=platform=='ios'
    ref=obj(name+'product','PBXFileReference',explicitFileType='wrapper.application',includeInIndex='0',path='Mac Jams.app',sourceTree='BUILT_PRODUCTS_DIR');products.append(ref)
    deps,links=package_dependencies(name)
    compile_files=[obj(name+ref,'PBXBuildFile',fileRef=ref) for ref in source_refs]
    phases=[obj(name+'sources','PBXSourcesBuildPhase',buildActionMask='2147483647',files=compile_files,runOnlyForDeploymentPostprocessing='0'),
            obj(name+'frameworks','PBXFrameworksBuildPhase',buildActionMask='2147483647',files=links,runOnlyForDeploymentPostprocessing='0'),
            obj(name+'resources','PBXResourcesBuildPhase',buildActionMask='2147483647',files=[obj(name+'assetbuild','PBXBuildFile',fileRef=asset)],runOnlyForDeploymentPostprocessing='0')]
    settings={'PRODUCT_NAME':'Mac Jams','EXECUTABLE_NAME':'MacLooper','PRODUCT_MODULE_NAME':'MacLooper','GENERATE_INFOPLIST_FILE':'YES','INFOPLIST_KEY_CFBundleDisplayName':'Mac Jams',
              'INFOPLIST_KEY_NSMicrophoneUsageDescription':'Mac Jams listens to your guitar interface to trigger and capture a loop. Live guitar is monitored by your interface.',
              'CURRENT_PROJECT_VERSION':'6','MARKETING_VERSION':'0.3.0','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'S37ZVC89JW',
              'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIconPad' if ipad else 'AppIconMac'}
    if ipad:
        settings.update({'SDKROOT':'iphoneos','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','IPHONEOS_DEPLOYMENT_TARGET':'18.0','TARGETED_DEVICE_FAMILY':'2','SUPPORTS_MACCATALYST':'NO','PRODUCT_BUNDLE_IDENTIFIER':'com.thoppe.maclooper',
                         'CODE_SIGN_ENTITLEMENTS':'MacLooper-iPad.entitlements','INFOPLIST_FILE':'MacLooper-iPad-Info.plist','INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','INFOPLIST_KEY_UILaunchScreen_Generation':'YES','INFOPLIST_KEY_UIFileSharingEnabled':'YES','INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace':'YES',
                         'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad':'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'})
    else:
        settings.update({'SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'14.0','SUPPORTED_PLATFORMS':'macosx','PRODUCT_BUNDLE_IDENTIFIER':'local.thoppe.maclooper','ENABLE_APP_SANDBOX':'NO','CODE_SIGN_IDENTITY':'-','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks'})
    return obj(name,'PBXNativeTarget',buildConfigurationList=configs(name,settings),buildPhases=phases,buildRules=[],dependencies=[],name=name,packageProductDependencies=deps,productName='Mac Jams',productReference=ref,productType='com.apple.product-type.application')
mac=app('MacLooper-macOS','mac');ipad=app('MacLooper-iPad','ios')
# Host-independent DSP/library tests also run inside the iPad test host.
testrefs=[]
for p in sorted((ROOT/'Tests/JamCoreTests').glob('*.swift'))+sorted((ROOT/'Tests/LooperCoreTests').glob('*.swift'))+sorted((ROOT/'Tests/MacLooperTests').glob('*.swift')):
    testrefs.append(obj(str(p.relative_to(ROOT)),'PBXFileReference',lastKnownFileType='sourcecode.swift',path=str(p.relative_to(ROOT)),sourceTree='SOURCE_ROOT'))
test_product=obj('testsproduct','PBXFileReference',explicitFileType='wrapper.cfbundle',path='MacLooper-iPadTests.xctest',sourceTree='BUILT_PRODUCTS_DIR');products.append(test_product)
deps,links=package_dependencies('ipadtests')
proxy=obj('testproxy','PBXContainerItemProxy',containerPortal=project,proxyType='1',remoteGlobalIDString=ipad,remoteInfo='MacLooper-iPad')
dependency=obj('testdependency','PBXTargetDependency',target=ipad,targetProxy=proxy)
tests=obj('ipadtests','PBXNativeTarget',buildConfigurationList=configs('ipadtests',{'SDKROOT':'iphoneos','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','IPHONEOS_DEPLOYMENT_TARGET':'18.0','TARGETED_DEVICE_FAMILY':'2','PRODUCT_NAME':'MacLooper-iPadTests','PRODUCT_BUNDLE_IDENTIFIER':'com.thoppe.maclooper.tests','GENERATE_INFOPLIST_FILE':'YES','DEVELOPMENT_TEAM':'S37ZVC89JW','CODE_SIGN_STYLE':'Automatic','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/Mac Jams.app/MacLooper','BUNDLE_LOADER':'$(TEST_HOST)'}),
    buildPhases=[obj('testsources','PBXSourcesBuildPhase',buildActionMask='2147483647',files=[obj('testbuild'+ref,'PBXBuildFile',fileRef=ref) for ref in testrefs],runOnlyForDeploymentPostprocessing='0'),obj('testframeworks','PBXFrameworksBuildPhase',buildActionMask='2147483647',files=links,runOnlyForDeploymentPostprocessing='0')],buildRules=[],dependencies=[dependency],name='MacLooper-iPadTests',packageProductDependencies=deps,productName='MacLooper-iPadTests',productReference=test_product,productType='com.apple.product-type.bundle.unit-test')
source_group=obj('sourcegroup','PBXGroup',children=source_refs,name='Shared App',sourceTree='<group>')
test_group=obj('testgroup','PBXGroup',children=testrefs,name='Shared Tests',sourceTree='<group>')
resource_group=obj('resourcegroup','PBXGroup',children=resource_refs,name='Resources',sourceTree='<group>')
product_group=obj('productgroup','PBXGroup',children=products,name='Products',sourceTree='<group>')
obj('root','PBXGroup',children=[source_group,test_group,resource_group,product_group],sourceTree='<group>')
obj('project','PBXProject',attributes={'LastUpgradeCheck':'2720','TargetAttributes':{ipad:{'DevelopmentTeam':'S37ZVC89JW'},tests:{'TestTargetID':ipad,'DevelopmentTeam':'S37ZVC89JW'}}},buildConfigurationList=configs('project',{}),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','Base'],mainGroup=root,productRefGroup=product_group,projectDirPath='',projectRoot='',packageReferences=[package,remote_package],targets=[mac,ipad,tests])
OUT.mkdir(exist_ok=True)
(OUT/'project.pbxproj').write_text('// !$*UTF8*$!\n'+encode({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project})+'\n')
schemes=OUT/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
def ref(target,name,product): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:MacLooper.xcodeproj"/>'
for target,name in [(mac,'MacLooper-macOS'),(ipad,'MacLooper-iPad')]:
    tests_xml=f'<TestableReference skipped="NO">{ref(tests,"MacLooper-iPadTests","MacLooper-iPadTests.xctest")}</TestableReference>' if target==ipad else ''
    xml=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2720" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(target,name,'Mac Jams.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{tests_xml}</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(target,name,'Mac Jams.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(target,name,'Mac Jams.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
    (schemes/(name+'.xcscheme')).write_text(xml)
print('Generated',OUT)
