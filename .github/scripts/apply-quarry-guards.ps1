$ErrorActionPreference = 'Stop'

$pmPath = 'Dumper\Generator\Private\Managers\PackageManager.cpp'
$pm = Get-Content -Raw $pmPath

$oldSet = @'
		for (int32 Dependency : Dependencies)
		{
			const int32 PackageIdx = ObjectArray::GetByIndex(Dependency).GetPackageIndex();


			if (bAllowToIncludeOwnPackage || PackageIdx != StructPackageIdx)
'@
$newSet = @'
		for (int32 Dependency : Dependencies)
		{
			UEObject DependencyObject = ObjectArray::GetByIndex(Dependency);
			if (!DependencyObject)
			{
				std::cerr << "[PackageManager] Skipping invalid dependency UObject index 0x" << std::hex << Dependency << std::dec << '\n';
				continue;
			}

			const int32 PackageIdx = DependencyObject.GetPackageIndex();
			if (PackageIdx < 0)
				continue;

			if (bAllowToIncludeOwnPackage || PackageIdx != StructPackageIdx)
'@
if (-not $pm.Contains($oldSet)) { throw 'SetPackageDependencies patch context not found.' }
$pm = $pm.Replace($oldSet, $newSet)

$oldEnum = @'
			UEObject DependencyObject = ObjectArray::GetByIndex(Dependency);

			if (!DependencyObject.IsA(EClassCastFlags::Enum))
'@
$newEnum = @'
			UEObject DependencyObject = ObjectArray::GetByIndex(Dependency);

			if (!DependencyObject)
				continue;

			if (!DependencyObject.IsA(EClassCastFlags::Enum))
'@
if (-not $pm.Contains($oldEnum)) { throw 'AddEnumPackageDependencies patch context not found.' }
$pm = $pm.Replace($oldEnum, $newEnum)

$oldStruct = @'
			UEObject Obj = ObjectArray::GetByIndex(DependencyStructIdx);

			if (Obj.GetPackageIndex() == StructPackageIndex && !Obj.IsA(EClassCastFlags::Enum))
'@
$newStruct = @'
			UEObject Obj = ObjectArray::GetByIndex(DependencyStructIdx);

			if (!Obj)
				continue;

			if (Obj.GetPackageIndex() == StructPackageIndex && !Obj.IsA(EClassCastFlags::Enum))
'@
if (-not $pm.Contains($oldStruct)) { throw 'AddStructDependencies patch context not found.' }
$pm = $pm.Replace($oldStruct, $newStruct)

$oldProp = @'
		if (Prop.IsA(EClassCastFlags::StructProperty))
		{
			Store.insert(Prop.Cast<UEStructProperty>().GetUnderlayingStruct().GetIndex());
		}
'@
$newProp = @'
		if (Prop.IsA(EClassCastFlags::StructProperty))
		{
			if (UEStruct UnderlayingStruct = Prop.Cast<UEStructProperty>().GetUnderlayingStruct())
				Store.insert(UnderlayingStruct.GetIndex());
		}
'@
if (-not $pm.Contains($oldProp)) { throw 'GetPropertyDependency struct patch context not found.' }
$pm = $pm.Replace($oldProp, $newProp)
Set-Content -Path $pmPath -Value $pm -NoNewline

$oaPath = 'Dumper\Engine\Private\Unreal\ObjectArray.cpp'
$oa = Get-Content -Raw $oaPath
$oldBounds = 'Index < 0 || Index > Num()'
$matches = ([regex]::Matches($oa, [regex]::Escape($oldBounds))).Count
if ($matches -lt 3) { throw "Expected at least 3 ObjectArray bounds checks, found $matches." }
$oa = $oa.Replace($oldBounds, 'Index < 0 || Index >= Num()')
Set-Content -Path $oaPath -Value $oa -NoNewline

$swPath = 'Dumper\Generator\Private\Wrappers\StructWrapper.cpp'
$sw = Get-Content -Raw $swPath

$oldIncludes = @'
#include "Wrappers/StructWrapper.h"
#include "Managers/MemberManager.h"
'@
$newIncludes = @'
#include "Wrappers/StructWrapper.h"
#include "Managers/MemberManager.h"
#include "OffsetFinder/Offsets.h"
#include "Platform.h"
'@
if (-not $sw.Contains($oldIncludes)) { throw 'StructWrapper include patch context not found.' }
$sw = $sw.Replace($oldIncludes, $newIncludes)

$oldTypeGuard = @'
    bool IsUnrealStructTypeSafe(const UEStruct& Struct, EClassCastFlags TypeFlag)
    {
        if (!Struct.GetAddress())
            return false;

        const UEClass StructClass = Struct.GetClass();
        if (!StructClass.GetAddress())
            return false;

        return StructClass.IsType(TypeFlag);
    }
'@
$newTypeGuard = @'
    bool IsUnrealStructTypeSafe(const UEStruct& Struct, EClassCastFlags TypeFlag)
    {
        const auto* StructAddress = static_cast<const uint8*>(Struct.GetAddress());
        if (!StructAddress || Platform::IsBadReadPtr(StructAddress))
            return false;

        const auto* ClassFieldAddress = StructAddress + Off::UObject::Class;
        if (Platform::IsBadReadPtr(ClassFieldAddress))
            return false;

        const UEClass StructClass = Struct.GetClass();
        const auto* StructClassAddress = static_cast<const uint8*>(StructClass.GetAddress());
        if (!StructClassAddress || Platform::IsBadReadPtr(StructClassAddress))
            return false;

        const auto* CastFlagsAddress = StructClassAddress + Off::UClass::CastFlags;
        if (Platform::IsBadReadPtr(CastFlagsAddress))
            return false;

        return StructClass.IsType(TypeFlag);
    }
'@
if (-not $sw.Contains($oldTypeGuard)) { throw 'StructWrapper stale UClass guard context not found.' }
$sw = $sw.Replace($oldTypeGuard, $newTypeGuard)
Set-Content -Path $swPath -Value $sw -NoNewline

Write-Host 'Applied Quarry dependency guards, ObjectArray bounds fix, and stale UClass readability guards.'
git diff -- Dumper/Generator/Private/Managers/PackageManager.cpp Dumper/Engine/Private/Unreal/ObjectArray.cpp Dumper/Generator/Private/Wrappers/StructWrapper.cpp
