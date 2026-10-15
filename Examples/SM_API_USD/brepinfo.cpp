// SPDX-License-Identifier: Apache-2.0
//
// brepinfo: open a USD file, report every BrepArray prim's Breps (face/edge/vertex counts),
// tessellate them with SmApiUsdTessellateBrepArray, and time each step. Fork addition (Android
// port): the same source builds for the host and for android-aarch64. See README.md.

#include <SmApiUsd.h>
#include <SmApiUsdTessellate.h>
#include <SmApiBrep.h>
#include <SmApiGeneral.h>
#include <SmApiQueries.h>
#include <SmApiTessellationParams.h>
#include <SmBrep.h> // Complete type for caller-owned Brep destruction, and GetVertices().

#include "UsdBrepSuppressPixarWarningsPush.h"
#include <pxr/usd/usd/prim.h>
#include <pxr/usd/usd/stage.h>
#include "UsdBrepSuppressPixarWarningsPop.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace
{
using Clock = std::chrono::steady_clock;

double MsSince(Clock::time_point t0)
{
    return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

struct Options
{
    const char* pFile = nullptr;
    SmTessellationParams sParams;  // SmTessellationDefaults
    bool bEdges = false;
    bool bJson = false;
};

// One packed Brep of a BrepArray prim.
struct BrepReport
{
    std::int64_t iIndex = -1;          // packed index; -1 = the prim as a whole
    bool bImported = false;
    std::string sImportMessage;
    long lFaces = 0, lEdges = 0, lVertices = 0;
    bool bTessellated = false;
    std::string sTessMessage;
    long lTriangles = 0, lPoints = 0, lFailedFaces = 0;
    int iBoundaryStatus = SM_ERR;      // SmApiTessellateBoundaries; failed curves keep zero counts
    bool bBoundaryOk = false;
    long lBoundaryPolylines = 0, lBoundaryPoints = 0;
};

struct PrimReport
{
    std::string sPath;
    std::vector<BrepReport> sBreps;
};

void Usage(FILE* pOut)
{
    std::fprintf(pOut,
        "usage: brepinfo <file.usd[c|a]> [--tol <chordHeight>] [--angle <deg>] [--edges] [--json]\n"
        "  --tol <h>     chord height tolerance, world units (default %g = off)\n"
        "  --angle <d>   curve and surface angle tolerance, degrees (default %g)\n"
        "  --edges       also sample Brep boundaries with SmApiTessellateBoundaries at --angle\n"
        "  --json        print one JSON object instead of text\n"
        "The omniSolid schema is found through OMNISOLID_PLUGIN_PATH, or PXR_PLUGINPATH_NAME if it\n"
        "lists the omniSolid/resources folder. Exit code: 0 ok, 1 a Brep failed, 2 usage,\n"
        "3 setup (schema plugin, stage open, no BrepArray prims).\n",
        SmTessellationDefaults::kChordHeightTol, SmTessellationDefaults::kCurveAngleTolDeg);
}

bool ParseDouble(const char* pText, double& rValue)
{
    char* pEnd = nullptr;
    rValue = std::strtod(pText, &pEnd);
    return pEnd != pText && *pEnd == '\0' && rValue >= 0.0;
}

bool ParseArgs(int argc, char** argv, Options& rOpts)
{
    for (int i = 1; i < argc; ++i)
    {
        const char* pArg = argv[i];
        if (!std::strcmp(pArg, "--tol") || !std::strcmp(pArg, "--angle"))
        {
            double dValue = 0.0;
            if (i + 1 >= argc || !ParseDouble(argv[++i], dValue))
            {
                std::fprintf(stderr, "brepinfo: %s needs a non-negative number\n", pArg);
                return false;
            }
            if (pArg[2] == 't')
                rOpts.sParams.dChordHeightTol = dValue;
            else
                rOpts.sParams.dCurveAngleTolDeg = rOpts.sParams.dSurfaceAngleTolDeg = dValue;
        }
        else if (!std::strcmp(pArg, "--edges"))
            rOpts.bEdges = true;
        else if (!std::strcmp(pArg, "--json"))
            rOpts.bJson = true;
        else if (!std::strcmp(pArg, "-h") || !std::strcmp(pArg, "--help"))
        {
            Usage(stdout);
            std::exit(0);
        }
        else if (pArg[0] == '-' || rOpts.pFile)
        {
            std::fprintf(stderr, "brepinfo: unexpected argument '%s'\n", pArg);
            return false;
        }
        else
            rOpts.pFile = pArg;
    }
    if (!rOpts.pFile)
    {
        std::fprintf(stderr, "brepinfo: no input file\n");
        return false;
    }
    if (rOpts.bEdges && rOpts.sParams.dCurveAngleTolDeg <= 0.0)
    {
        std::fprintf(stderr, "brepinfo: --edges needs a positive --angle\n");
        return false;
    }
    return true;
}

// Same discovery as SmApiUsdImportBreps (every BrepArray-typed descendant), so prims line up with
// its import results.
void CollectBrepArrayPrims(const pxr::UsdPrim& crPrim, std::vector<pxr::UsdPrim>& rPrims)
{
    for (const pxr::UsdPrim& child : crPrim.GetAllChildren())
    {
        if (child.GetTypeName() == pxr::TfToken("BrepArray"))
            rPrims.push_back(child);
        CollectBrepArrayPrims(child, rPrims);
    }
}

BrepReport& ReportFor(PrimReport& rPrim, std::int64_t iIndex)
{
    for (BrepReport& rBrep : rPrim.sBreps)
        if (rBrep.iIndex == iIndex)
            return rBrep;
    rPrim.sBreps.emplace_back();
    rPrim.sBreps.back().iIndex = iIndex;
    return rPrim.sBreps.back();
}

std::string JsonString(const std::string& crText)
{
    std::string sOut = "\"";
    for (unsigned char c : crText)
    {
        if (c == '"' || c == '\\')
        {
            sOut += '\\';
            sOut += static_cast<char>(c);
        }
        else if (c < 0x20)
        {
            char buf[8];
            std::snprintf(buf, sizeof buf, "\\u%04x", c);
            sOut += buf;
        }
        else
            sOut += static_cast<char>(c);
    }
    return sOut + "\"";
}

struct Totals
{
    long lBreps = 0, lFailed = 0, lFaces = 0, lEdges = 0, lVertices = 0;
    long lTriangles = 0, lPoints = 0, lBoundaryPoints = 0;
};

Totals Sum(const std::vector<PrimReport>& crPrims)
{
    Totals t;
    for (const PrimReport& p : crPrims)
        for (const BrepReport& b : p.sBreps)
        {
            if (b.iIndex >= 0)
                ++t.lBreps;
            if (!b.bImported || !b.bTessellated || b.lFailedFaces)
                ++t.lFailed;
            t.lFaces += b.lFaces;
            t.lEdges += b.lEdges;
            t.lVertices += b.lVertices;
            t.lTriangles += b.lTriangles;
            t.lPoints += b.lPoints;
            t.lBoundaryPoints += b.lBoundaryPoints;
        }
    return t;
}

void PrintText(const Options& crOpts, const std::vector<PrimReport>& crPrims, const Totals& crT,
               double dOpenMs, double dImportMs, double dTessMs, double dEdgesMs)
{
    const SmTessellationParams& p = crOpts.sParams;
    std::printf("file: %s\n", crOpts.pFile);
    std::printf("params: chordHeight=%g angle=%g/%g deg (curve/surface)\n", p.dChordHeightTol,
                p.dCurveAngleTolDeg, p.dSurfaceAngleTolDeg);
    for (const PrimReport& prim : crPrims)
    {
        std::printf("%s  breps=%zu\n", prim.sPath.c_str(), prim.sBreps.size());
        for (const BrepReport& b : prim.sBreps)
        {
            std::printf("  [%lld]", static_cast<long long>(b.iIndex));
            if (b.bImported)
                std::printf(" faces=%ld edges=%ld vertices=%ld", b.lFaces, b.lEdges, b.lVertices);
            else
                std::printf(" import FAILED: %s", b.sImportMessage.c_str());
            if (b.bTessellated)
                std::printf(" triangles=%ld points=%ld", b.lTriangles, b.lPoints);
            else
                std::printf(" tessellation FAILED: %s", b.sTessMessage.c_str());
            if (b.lFailedFaces)
                std::printf(" failedFaces=%ld", b.lFailedFaces);
            if (crOpts.bEdges && b.bImported)
            {
                std::printf(" boundaryPolylines=%ld boundaryPoints=%ld", b.lBoundaryPolylines, b.lBoundaryPoints);
                if (!b.bBoundaryOk)
                    std::printf(" boundaryStatus=%d", b.iBoundaryStatus);
            }
            std::printf("\n");
        }
    }
    std::printf("total: prims=%zu breps=%ld faces=%ld edges=%ld vertices=%ld triangles=%ld points=%ld",
                crPrims.size(), crT.lBreps, crT.lFaces, crT.lEdges, crT.lVertices, crT.lTriangles, crT.lPoints);
    if (crOpts.bEdges)
        std::printf(" boundaryPoints=%ld", crT.lBoundaryPoints);
    std::printf(" failed=%ld\n", crT.lFailed);
    std::printf("time: open %.1f ms, import %.1f ms, tessellate %.1f ms", dOpenMs, dImportMs, dTessMs);
    if (crOpts.bEdges)
        std::printf(", edges %.1f ms", dEdgesMs);
    std::printf("\n");
}

void PrintJson(const Options& crOpts, const std::vector<PrimReport>& crPrims, const Totals& crT,
               double dOpenMs, double dImportMs, double dTessMs, double dEdgesMs)
{
    const SmTessellationParams& p = crOpts.sParams;
    std::printf("{\"file\":%s,", JsonString(crOpts.pFile).c_str());
    std::printf("\"params\":{\"chordHeightTol\":%.17g,\"curveAngleTolDeg\":%.17g,\"surfaceAngleTolDeg\":%.17g,"
                "\"maxEdgeLength\":%.17g,\"maxAspectRatio\":%.17g,\"edges\":%s},",
                p.dChordHeightTol, p.dCurveAngleTolDeg, p.dSurfaceAngleTolDeg, p.dMaxEdgeLength,
                p.dMaxAspectRatio, crOpts.bEdges ? "true" : "false");
    std::printf("\"timingsMs\":{\"open\":%.3f,\"import\":%.3f,\"tessellate\":%.3f", dOpenMs, dImportMs, dTessMs);
    if (crOpts.bEdges)
        std::printf(",\"edges\":%.3f", dEdgesMs);
    std::printf("},\"prims\":[");
    for (size_t pi = 0; pi < crPrims.size(); ++pi)
    {
        const PrimReport& prim = crPrims[pi];
        std::printf("%s{\"path\":%s,\"breps\":[", pi ? "," : "", JsonString(prim.sPath).c_str());
        for (size_t bi = 0; bi < prim.sBreps.size(); ++bi)
        {
            const BrepReport& b = prim.sBreps[bi];
            std::printf("%s{\"index\":%lld,\"imported\":%s,\"faces\":%ld,\"edges\":%ld,\"vertices\":%ld,"
                        "\"tessellated\":%s,\"triangles\":%ld,\"points\":%ld,\"failedFaces\":%ld",
                        bi ? "," : "", static_cast<long long>(b.iIndex), b.bImported ? "true" : "false",
                        b.lFaces, b.lEdges, b.lVertices, b.bTessellated ? "true" : "false", b.lTriangles,
                        b.lPoints, b.lFailedFaces);
            if (crOpts.bEdges)
                std::printf(",\"boundaryOk\":%s,\"boundaryStatus\":%d,\"boundaryPolylines\":%ld,\"boundaryPoints\":%ld",
                            b.bBoundaryOk ? "true" : "false", b.iBoundaryStatus, b.lBoundaryPolylines,
                            b.lBoundaryPoints);
            if (!b.sImportMessage.empty())
                std::printf(",\"importMessage\":%s", JsonString(b.sImportMessage).c_str());
            if (!b.sTessMessage.empty())
                std::printf(",\"tessMessage\":%s", JsonString(b.sTessMessage).c_str());
            std::printf("}");
        }
        std::printf("]}");
    }
    std::printf("],\"totals\":{\"prims\":%zu,\"breps\":%ld,\"faces\":%ld,\"edges\":%ld,\"vertices\":%ld,"
                "\"triangles\":%ld,\"points\":%ld,\"boundaryPoints\":%ld,\"failed\":%ld},\"ok\":%s}\n",
                crPrims.size(), crT.lBreps, crT.lFaces, crT.lEdges, crT.lVertices, crT.lTriangles, crT.lPoints,
                crT.lBoundaryPoints, crT.lFailed, crT.lFailed ? "false" : "true");
}

int Fail(const Options& crOpts, const std::string& crMessage)
{
    if (crOpts.bJson)
        std::printf("{\"file\":%s,\"ok\":false,\"error\":%s}\n", JsonString(crOpts.pFile).c_str(),
                    JsonString(crMessage).c_str());
    std::fprintf(stderr, "brepinfo: %s\n", crMessage.c_str());
    return 3;
}
} // namespace

int main(int argc, char** argv)
{
    Options opts;
    if (!ParseArgs(argc, argv, opts))
    {
        Usage(stderr);
        return 2;
    }

    // Before any stage is opened (see SmApiUsdEnsurePluginRegistered). Succeeds without
    // OMNISOLID_PLUGIN_PATH when PXR_PLUGINPATH_NAME already brought in omniSolid/resources.
    SmApiCreateContext();
    if (SmApiUsdEnsurePluginRegistered() != SM_SUCCESS)
        return Fail(opts, "cannot register the omniSolid schema plugin: set OMNISOLID_PLUGIN_PATH to its "
                          "resources folder, or add that folder to PXR_PLUGINPATH_NAME");

    // 1. Stage open.
    Clock::time_point t0 = Clock::now();
    pxr::UsdStageRefPtr stage = pxr::UsdStage::Open(opts.pFile);
    const double dOpenMs = MsSince(t0);
    if (!stage)
        return Fail(opts, std::string("cannot open USD stage ") + opts.pFile);

    std::vector<pxr::UsdPrim> sPrims;
    CollectBrepArrayPrims(stage->GetPseudoRoot(), sPrims);
    if (sPrims.empty())
        return Fail(opts, std::string("no BrepArray prims in ") + opts.pFile);

    std::vector<PrimReport> sReports(sPrims.size());
    std::map<std::string, size_t> primIndex;
    for (size_t i = 0; i < sPrims.size(); ++i)
    {
        sReports[i].sPath = sPrims[i].GetPath().GetString();
        primIndex[sReports[i].sPath] = i;
    }

    // 2. Import every packed Brep into SMLib (healer on, the library default), keeping the
    //    successful ones when others fail. SmApiUsdImportBreps reads the file itself; the layer is
    //    already loaded by the stage above, so this times composition + conversion + healing.
    std::vector<SmBrep*> sBreps;
    std::vector<SmApiUsdBrepImportResult> sImports;
    t0 = Clock::now();
    const SmStatus importStatus = SmApiUsdImportBreps(opts.pFile, sBreps, TRUE, TRUE, &sImports);
    const double dImportMs = MsSince(t0);
    if (importStatus != SM_SUCCESS)
    {
        for (SmBrep* pBrep : sBreps)
            delete pBrep;
        return Fail(opts, "SmApiUsdImportBreps failed with status " + std::to_string(importStatus));
    }

    // Indices, not BrepReport pointers: ReportFor() may grow a prim's vector.
    struct ImportedBrep
    {
        size_t lPrim;
        std::int64_t iIndex;
        SmBrep* pBrep;
    };
    std::vector<ImportedBrep> sImported;
    for (const SmApiUsdBrepImportResult& r : sImports)
    {
        auto it = primIndex.find(r.m_sPrimPath);
        if (it == primIndex.end())
            continue;
        BrepReport& rBrep = ReportFor(sReports[it->second], r.m_iPackedBrepIndex);
        rBrep.bImported = r.m_sStatus == SM_SUCCESS && r.m_pBrep;
        rBrep.sImportMessage = r.m_sMessage;
        if (!rBrep.bImported)
            continue;
        SmTArray<SmFace*> sFaces;
        SmTArray<SmEdge*> sEdges;
        SmTArray<SmVertex*> sVertices;
        SmApiGetFaces(r.m_pBrep, sFaces);
        SmApiGetEdges(r.m_pBrep, sEdges);
        r.m_pBrep->GetVertices(sVertices);
        rBrep.lFaces = static_cast<long>(sFaces.GetSize());
        rBrep.lEdges = static_cast<long>(sEdges.GetSize());
        rBrep.lVertices = static_cast<long>(sVertices.GetSize());
        sImported.push_back({it->second, r.m_iPackedBrepIndex, r.m_pBrep});
    }

    // 3. Tessellate each BrepArray prim: what a viewer calls. It imports (and heals) the prim
    //    again in a private context, so this time includes that import.
    t0 = Clock::now();
    for (size_t i = 0; i < sPrims.size(); ++i)
    {
        std::vector<SmApiUsdTessellatedBrep> sMeshes;
        SmApiUsdTessellateBrepArray(sPrims[i], opts.sParams, TRUE, 0.0, sMeshes);
        for (const SmApiUsdTessellatedBrep& m : sMeshes)
        {
            BrepReport& rBrep = ReportFor(sReports[i], m.m_iPackedBrepIndex);
            rBrep.bTessellated = m.m_sStatus == SM_SUCCESS;
            rBrep.sTessMessage = m.m_sMessage;
            rBrep.lFailedFaces = static_cast<long>(m.m_sFailedFaces.size());
            rBrep.lPoints = static_cast<long>(m.m_sPoints.size());
            for (int n : m.m_sFaceVertexCounts)
                rBrep.lTriangles += n >= 3 ? n - 2 : 0;
        }
    }
    const double dTessMs = MsSince(t0);

    // 4. Optional boundary polylines from the imported Breps.
    double dEdgesMs = 0.0;
    if (opts.bEdges)
    {
        t0 = Clock::now();
        for (const ImportedBrep& rEntry : sImported)
        {
            BrepReport& rBrep = ReportFor(sReports[rEntry.lPrim], rEntry.iIndex);
            SmTArray<SmPoint3d> sPoints;
            SmTArray<ULONG> sCounts;
            SmTArray<SmEdge*> sEdges;
            rBrep.iBoundaryStatus =
                SmApiTessellateBoundaries(rEntry.pBrep, opts.sParams.dCurveAngleTolDeg, sPoints, sCounts, sEdges);
            rBrep.bBoundaryOk = rBrep.iBoundaryStatus == SM_SUCCESS;
            rBrep.lBoundaryPolylines = static_cast<long>(sCounts.GetSize());
            rBrep.lBoundaryPoints = static_cast<long>(sPoints.GetSize());
        }
        dEdgesMs = MsSince(t0);
    }

    for (SmBrep* pBrep : sBreps)
        delete pBrep;

    const Totals totals = Sum(sReports);
    if (opts.bJson)
        PrintJson(opts, sReports, totals, dOpenMs, dImportMs, dTessMs, dEdgesMs);
    else
        PrintText(opts, sReports, totals, dOpenMs, dImportMs, dTessMs, dEdgesMs);
    if (totals.lFailed)
        std::fprintf(stderr, "brepinfo: %ld Brep(s) failed to import or tessellate\n", totals.lFailed);
    return totals.lFailed ? 1 : 0;
}
