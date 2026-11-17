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

$offPath = 'Dumper\Engine\Private\OffsetFinder\Offsets.cpp'
$off = Get-Content -Raw $offPath
$oldGWorld = @'
/* UWorld */
void Off::InSDK::World::InitGWorld()
{
	UEClass UWorld = ObjectArray::FindClassFast("World");

	for (UEObject Obj : ObjectArray())
	{
		if (Obj.HasAnyFlags(EObjectFlags::ClassDefaultObject) || !Obj.IsA(UWorld))
			continue;

		/* Try to find a pointer to the word, aka UWorld** GWorld */
		auto Results = Platform::FindAllAlignedValuesInProcess(Obj.GetAddress());

		void* Result = nullptr;
		if (Results.size())
		{
			if (Results.size() == 1)
			{
				Result = Results[0];
			}
			else if (Results.size() == 2)
			{
				auto ObjAddress = reinterpret_cast<uintptr_t>(Obj.GetAddress());
				auto PossibleGWorld = reinterpret_cast<volatile uintptr_t*>(Results[0]);
				auto CurrentValue = *PossibleGWorld;

				for (int i = 0; CurrentValue == ObjAddress && i < 50; ++i)
				{
					::Sleep(1);
					CurrentValue = *PossibleGWorld;
				}
				if (CurrentValue == ObjAddress)
				{
					Result = Results[0];
				}
				else
				{
					Result = Results[1];
					std::cerr << std::format("Filter GActiveLogWorld at 0x{:X}\n\n", reinterpret_cast<uintptr_t>(PossibleGWorld));
				}
			}
			else
			{
				std::cerr << std::format("Detected {} GWorld \n\n", Results.size());
			}
		}

		/* Pointer to UWorld* couldn't be found */
		if (Result)
		{
			Off::InSDK::World::GWorld = Platform::GetOffset(Result);
			std::cerr << std::format("GWorld-Offset: 0x{:X}\n\n", Off::InSDK::World::GWorld);
			break;
		}
	}

	if (Off::InSDK::World::GWorld == 0x0)
		std::cerr << std::format("\nGWorld WAS NOT FOUND!!!!!!!!!\n\n");
}
'@
$newGWorld = @'
/* UWorld */
void Off::InSDK::World::InitGWorld()
{
	UEClass UWorld = ObjectArray::FindClassFast("World");
	if (!UWorld)
	{
		std::cerr << "\nUWorld class was not found; cannot resolve GWorld.\n\n";
		return;
	}

	auto CountRipRelativeReferences = [](const void* Target) -> int32
	{
#if defined(PLATFORM_WINDOWS64)
		const SectionInfo TextSection = Platform::GetSectionInfo(".text");
		if (!TextSection.IsValid())
			return 0;

		const uintptr_t TargetAddress = reinterpret_cast<uintptr_t>(Target);
		int32 ReferenceCount = 0;

		Platform::IterateSectionWithCallback(TextSection, [TargetAddress, &ReferenceCount](void* Address) -> bool
			{
				const auto* Bytes = static_cast<const uint8_t*>(Address);
				const uint8_t Rex = Bytes[0];
				const uint8_t Opcode = Bytes[1];
				const uint8_t ModRM = Bytes[2];

				/* x64 RIP-relative MOV/LEA: REX + 8B/89/8D + mod=00,r/m=101 + disp32 */
				if ((Rex & 0xF0) != 0x40 || (Opcode != 0x8B && Opcode != 0x89 && Opcode != 0x8D) || (ModRM & 0xC7) != 0x05)
					return false;

				const int32 RelativeOffset = *reinterpret_cast<const int32*>(Bytes + 3);
				const uintptr_t ResolvedTarget = reinterpret_cast<uintptr_t>(Bytes) + 7 + static_cast<intptr_t>(RelativeOffset);
				if (ResolvedTarget == TargetAddress)
					++ReferenceCount;

				return false;
			}, 1, 7);

		return ReferenceCount;
#else
		return 0;
#endif
	};

	for (UEObject Obj : ObjectArray())
	{
		if (Obj.HasAnyFlags(EObjectFlags::ClassDefaultObject) || !Obj.IsA(UWorld))
			continue;

		/* Try to find every module-global pointer currently pointing at this UWorld. */
		auto Results = Platform::FindAllAlignedValuesInProcess(Obj.GetAddress());
		if (Results.empty())
			continue;

		const uintptr_t ObjAddress = reinterpret_cast<uintptr_t>(Obj.GetAddress());
		void* BestResult = nullptr;
		int32 BestReferenceCount = -1;
		bool bBestScoreTied = false;
		int32 StableCandidateCount = 0;

		std::cerr << std::format("Detected {} GWorld candidate(s)\n", Results.size());

		for (size_t CandidateIndex = 0; CandidateIndex < Results.size(); ++CandidateIndex)
		{
			void* Candidate = Results[CandidateIndex];
			if (!Candidate || Platform::IsBadReadPtr(Candidate))
				continue;

			auto* CandidateValue = reinterpret_cast<volatile uintptr_t*>(Candidate);
			uintptr_t CurrentValue = *CandidateValue;
			if (CurrentValue != ObjAddress)
				continue;

			/* GActiveLogWorld is transient. Preserve the old filter, but apply it to every candidate. */
			bool bChanged = false;
			for (int i = 0; i < 50; ++i)
			{
				::Sleep(1);
				CurrentValue = *CandidateValue;
				if (CurrentValue != ObjAddress)
				{
					bChanged = true;
					break;
				}
			}

			const uintptr_t CandidateOffset = Platform::GetOffset(Candidate);
			if (bChanged)
			{
				std::cerr << std::format("  candidate[{}] 0x{:X}: transient, filtered as GActiveLogWorld-like\n", CandidateIndex, CandidateOffset);
				continue;
			}

			++StableCandidateCount;
			const int32 ReferenceCount = CountRipRelativeReferences(Candidate);
			std::cerr << std::format("  candidate[{}] 0x{:X}: stable, {} .text RIP reference(s)\n", CandidateIndex, CandidateOffset, ReferenceCount);

			if (ReferenceCount > BestReferenceCount)
			{
				BestResult = Candidate;
				BestReferenceCount = ReferenceCount;
				bBestScoreTied = false;
			}
			else if (ReferenceCount == BestReferenceCount)
			{
				bBestScoreTied = true;
			}
		}

		/* A single stable candidate is safe even if the compiler emitted no recognized reference pattern. */
		if (StableCandidateCount == 1 && BestResult)
		{
			Off::InSDK::World::GWorld = Platform::GetOffset(BestResult);
		}
		/* With multiple candidates, only accept a unique, code-referenced winner. */
		else if (BestResult && BestReferenceCount > 0 && !bBestScoreTied)
		{
			Off::InSDK::World::GWorld = Platform::GetOffset(BestResult);
		}

		if (Off::InSDK::World::GWorld != 0x0)
		{
			std::cerr << std::format("Selected GWorld-Offset: 0x{:X} ({} RIP reference(s))\n\n", Off::InSDK::World::GWorld, BestReferenceCount);
			break;
		}

		std::cerr << "GWorld candidates remained ambiguous; refusing to emit an unsafe offset.\n\n";
	}

	if (Off::InSDK::World::GWorld == 0x0)
		std::cerr << "\nGWorld WAS NOT FOUND!!!!!!!!!\n\n";
}
'@
if (-not $off.Contains($oldGWorld)) { throw 'InitGWorld multi-candidate patch context not found.' }
$off = $off.Replace($oldGWorld, $newGWorld)
Set-Content -Path $offPath -Value $off -NoNewline

Write-Host 'Applied Quarry dependency guards, ObjectArray bounds fix, stale UClass guards, and multi-candidate GWorld scoring.'
git diff -- Dumper/Generator/Private/Managers/PackageManager.cpp Dumper/Engine/Private/Unreal/ObjectArray.cpp Dumper/Generator/Private/Wrappers/StructWrapper.cpp Dumper/Engine/Private/OffsetFinder/Offsets.cpp
