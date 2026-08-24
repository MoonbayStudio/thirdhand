import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PNG } from "pngjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectDirectory = path.resolve(scriptDirectory, "..");
const sourcePath = path.join(
  projectDirectory,
  "public",
  "third-hand-logo-source.png",
);
const outputDirectory = path.join(projectDirectory, "public", "layers");

const source = PNG.sync.read(fs.readFileSync(sourcePath));
const { width, height, data } = source;
const pixelCount = width * height;

const seedThreshold = 10;
const coreThreshold = 64;
const fringeRadius = 3;
const cleanMatteCoreRadius = 8;
const cleanMatteAlphaFloor = 8;

const signal = new Uint8Array(pixelCount);
for (let pixel = 0; pixel < pixelCount; pixel++) {
  const offset = pixel * 4;
  signal[pixel] = Math.max(
    255 - data[offset],
    255 - data[offset + 1],
    255 - data[offset + 2],
  );
}

const seedLabels = new Int32Array(pixelCount);
seedLabels.fill(-1);

const components = [];
const queue = new Int32Array(pixelCount);

for (let seed = 0; seed < pixelCount; seed++) {
  if (signal[seed] < seedThreshold || seedLabels[seed] !== -1) {
    continue;
  }

  const id = components.length;
  let head = 0;
  let tail = 0;
  queue[tail++] = seed;
  seedLabels[seed] = id;

  let area = 0;
  let minX = width;
  let maxX = 0;
  let minY = height;
  let maxY = 0;

  while (head < tail) {
    const pixel = queue[head++];
    const x = pixel % width;
    const y = Math.floor(pixel / width);

    area++;
    minX = Math.min(minX, x);
    maxX = Math.max(maxX, x);
    minY = Math.min(minY, y);
    maxY = Math.max(maxY, y);

    for (let dy = -1; dy <= 1; dy++) {
      for (let dx = -1; dx <= 1; dx++) {
        if (dx === 0 && dy === 0) {
          continue;
        }

        const nextX = x + dx;
        const nextY = y + dy;
        if (nextX < 0 || nextX >= width || nextY < 0 || nextY >= height) {
          continue;
        }

        const nextPixel = nextY * width + nextX;
        if (
          signal[nextPixel] >= seedThreshold &&
          seedLabels[nextPixel] === -1
        ) {
          seedLabels[nextPixel] = id;
          queue[tail++] = nextPixel;
        }
      }
    }
  }

  components.push({ id, area, minX, maxX, minY, maxY });
}

const findComponentNear = (x, y) => {
  let best = null;

  for (let radius = 0; radius <= 20; radius++) {
    for (let dy = -radius; dy <= radius; dy++) {
      for (let dx = -radius; dx <= radius; dx++) {
        if (Math.max(Math.abs(dx), Math.abs(dy)) !== radius) {
          continue;
        }

        const candidateX = x + dx;
        const candidateY = y + dy;
        if (
          candidateX < 0 ||
          candidateX >= width ||
          candidateY < 0 ||
          candidateY >= height
        ) {
          continue;
        }

        const id = seedLabels[candidateY * width + candidateX];
        if (id === -1 || components[id].area < 500) {
          continue;
        }

        const distance = dx * dx + dy * dy;
        if (best === null || distance < best.distance) {
          best = { id, distance };
        }
      }
    }

    if (best !== null) {
      return best.id;
    }
  }

  throw new Error(`No component found near ${x}, ${y}`);
};

const isInsideEllipse = (x, y, centerX, centerY, radiusX, radiusY) => {
  const normalizedX = (x - centerX) / radiusX;
  const normalizedY = (y - centerY) / radiusY;
  return normalizedX * normalizedX + normalizedY * normalizedY <= 1;
};

const isInsidePolygon = (x, y, points) => {
  let inside = false;

  for (
    let index = 0, previous = points.length - 1;
    index < points.length;
    previous = index++
  ) {
    const [currentX, currentY] = points[index];
    const [previousX, previousY] = points[previous];
    const crossesScanline = currentY > y !== previousY > y;

    if (
      crossesScanline &&
      x <
        ((previousX - currentX) * (y - currentY)) / (previousY - currentY) +
          currentX
    ) {
      inside = !inside;
    }
  }

  return inside;
};

const makeTopHeadMaskAt = (centerX, centerY) => (x, y) =>
  isInsideEllipse(x, y, centerX, centerY, 72, 66) ||
  isInsidePolygon(x, y, [
    [centerX - 55, centerY + 31],
    [centerX - 56, centerY + 73],
    [centerX - 16, centerY + 53],
  ]);

const headMasks = {
  top: makeTopHeadMaskAt(349, 401),
  left: makeTopHeadMaskAt(211, 594),
  right: makeTopHeadMaskAt(481, 594),
};

const translatedHeadCenters = {
  "orbit-head-left": [211, 594],
  "orbit-head-right": [481, 594],
};

const headGradientPalettes = {
  "orbit-head-left": {
    topLeft: [78, 108, 251],
    topRight: [121, 150, 252],
    bottomLeft: [63, 92, 239],
    bottomRight: [113, 140, 255],
  },
  "orbit-head-right": {
    topLeft: [199, 88, 226],
    topRight: [255, 119, 222],
    bottomLeft: [205, 96, 229],
    bottomRight: [253, 114, 219],
  },
};

const mixChannel = (from, to, progress) =>
  Math.round(from + (to - from) * progress);

const mixColor = (from, to, progress) =>
  from.map((channel, index) => mixChannel(channel, to[index], progress));

const getCleanHeadColor = (assetName, localX, localY) => {
  const palette = headGradientPalettes[assetName];
  const horizontal = Math.max(0, Math.min(1, (localX + 60) / 120));
  const vertical = Math.max(0, Math.min(1, (localY + 50) / 100));
  const top = mixColor(palette.topLeft, palette.topRight, horizontal);
  const bottom = mixColor(palette.bottomLeft, palette.bottomRight, horizontal);

  return mixColor(top, bottom, vertical);
};

const assetDefinitions = [
  {
    name: "hand",
    samples: [[180, 760]],
    cleanMatte: true,
  },
  {
    name: "orbit-head-top",
    samples: [[350, 385]],
    includePixel: headMasks.top,
  },
  {
    name: "orbit-head-left",
    samples: [[210, 590]],
    includePixel: headMasks.left,
  },
  {
    name: "orbit-head-right",
    samples: [[480, 590]],
    includePixel: headMasks.right,
  },
  {
    name: "orbit-star",
    samples: [[350, 545]],
  },
  {
    name: "third-t",
    samples: [[650, 470]],
    cleanMatte: true,
    cleanText: true,
  },
  {
    name: "third-h",
    samples: [[775, 470]],
    cleanMatte: true,
    cleanText: true,
  },
  {
    name: "third-i-stem",
    samples: [[900, 540]],
    cleanMatte: true,
    cleanText: true,
  },
  {
    name: "third-r",
    samples: [[955, 530]],
    cleanMatte: true,
    cleanText: true,
  },
  {
    name: "third-d",
    samples: [[1100, 470]],
    cleanMatte: true,
    cleanText: true,
  },
  {
    name: "hand-h",
    samples: [[650, 680]],
    cleanMatte: true,
    cleanText: true,
  },
  {
    name: "hand-a",
    samples: [[820, 730]],
    cleanMatte: true,
    cleanText: true,
  },
  {
    name: "hand-n",
    samples: [[940, 730]],
    cleanMatte: true,
    cleanText: true,
  },
  {
    name: "hand-d",
    samples: [[1090, 680]],
    cleanMatte: true,
    cleanText: true,
  },
  {
    name: "i-dot",
    samples: [[902, 460]],
    cleanMatte: true,
  },
].map((asset) => ({
  ...asset,
  componentIds: [
    ...new Set(asset.samples.map(([x, y]) => findComponentNear(x, y))),
  ],
}));

const claimedComponents = new Map();
for (const asset of assetDefinitions) {
  for (const id of asset.componentIds) {
    const previous = claimedComponents.get(id);
    if (previous && !asset.includePixel) {
      throw new Error(
        `Component ${id} is shared by ${previous} and ${asset.name}`,
      );
    }
    if (!asset.includePixel) {
      claimedComponents.set(id, asset.name);
    }
  }
}

const assignedLabels = new Int32Array(seedLabels);
const distances = new Uint8Array(pixelCount);
distances.fill(255);

const coreMask = new Uint8Array(pixelCount);
for (let pixel = 0; pixel < pixelCount; pixel++) {
  const componentId = seedLabels[pixel];
  if (componentId === -1 || signal[pixel] < coreThreshold) {
    continue;
  }

  const x = pixel % width;
  const y = Math.floor(pixel / width);
  let isCore = true;

  for (let dy = -2; dy <= 2 && isCore; dy++) {
    for (let dx = -2; dx <= 2; dx++) {
      const nextX = x + dx;
      const nextY = y + dy;
      if (
        nextX < 0 ||
        nextX >= width ||
        nextY < 0 ||
        nextY >= height ||
        seedLabels[nextY * width + nextX] !== componentId
      ) {
        isCore = false;
        break;
      }
    }
  }

  if (isCore) {
    coreMask[pixel] = 1;
  }
}

const cleanMatteCoreMask = new Uint8Array(pixelCount);
for (let pixel = 0; pixel < pixelCount; pixel++) {
  const componentId = seedLabels[pixel];
  if (componentId === -1 || coreMask[pixel] === 0) {
    continue;
  }

  const x = pixel % width;
  const y = Math.floor(pixel / width);
  let isDeepCore = true;

  for (
    let dy = -cleanMatteCoreRadius;
    dy <= cleanMatteCoreRadius && isDeepCore;
    dy++
  ) {
    for (let dx = -cleanMatteCoreRadius; dx <= cleanMatteCoreRadius; dx++) {
      if (dx * dx + dy * dy > cleanMatteCoreRadius ** 2) {
        continue;
      }

      const nextX = x + dx;
      const nextY = y + dy;
      if (
        nextX < 0 ||
        nextX >= width ||
        nextY < 0 ||
        nextY >= height ||
        seedLabels[nextY * width + nextX] !== componentId
      ) {
        isDeepCore = false;
        break;
      }
    }
  }

  if (isDeepCore) {
    cleanMatteCoreMask[pixel] = 1;
  }
}

const cleanTextComponentIds = new Set(
  assetDefinitions
    .filter((asset) => asset.cleanText)
    .flatMap((asset) => asset.componentIds),
);
const cleanTextChannelSamples = [[], [], []];
for (let pixel = 0; pixel < pixelCount; pixel++) {
  if (
    cleanMatteCoreMask[pixel] === 0 ||
    !cleanTextComponentIds.has(seedLabels[pixel])
  ) {
    continue;
  }

  const offset = pixel * 4;
  cleanTextChannelSamples[0].push(data[offset]);
  cleanTextChannelSamples[1].push(data[offset + 1]);
  cleanTextChannelSamples[2].push(data[offset + 2]);
}
const cleanTextColor = cleanTextChannelSamples.map((samples) => {
  samples.sort((left, right) => left - right);
  return samples[Math.floor(samples.length / 2)];
});

let fringeHead = 0;
let fringeTail = 0;
for (let pixel = 0; pixel < pixelCount; pixel++) {
  if (seedLabels[pixel] !== -1) {
    queue[fringeTail++] = pixel;
    distances[pixel] = 0;
  }
}

while (fringeHead < fringeTail) {
  const pixel = queue[fringeHead++];
  const distance = distances[pixel];
  if (distance >= fringeRadius) {
    continue;
  }

  const x = pixel % width;
  const y = Math.floor(pixel / width);

  for (let dy = -1; dy <= 1; dy++) {
    for (let dx = -1; dx <= 1; dx++) {
      if (dx === 0 && dy === 0) {
        continue;
      }

      const nextX = x + dx;
      const nextY = y + dy;
      if (nextX < 0 || nextX >= width || nextY < 0 || nextY >= height) {
        continue;
      }

      const nextPixel = nextY * width + nextX;
      if (distances[nextPixel] !== 255) {
        continue;
      }

      assignedLabels[nextPixel] = assignedLabels[pixel];
      distances[nextPixel] = distance + 1;
      queue[fringeTail++] = nextPixel;
    }
  }
}

const nearestCoreColor = (
  pixel,
  componentId,
  selectedCoreMask = coreMask,
  averageCandidates = false,
) => {
  const x = pixel % width;
  const y = Math.floor(pixel / width);

  for (let radius = 1; radius <= 40; radius++) {
    let bestPixel = -1;
    let bestDistance = Number.POSITIVE_INFINITY;
    let weightedRed = 0;
    let weightedGreen = 0;
    let weightedBlue = 0;
    let totalWeight = 0;

    for (let dy = -radius; dy <= radius; dy++) {
      for (let dx = -radius; dx <= radius; dx++) {
        if (Math.max(Math.abs(dx), Math.abs(dy)) !== radius) {
          continue;
        }

        const candidateX = x + dx;
        const candidateY = y + dy;
        if (
          candidateX < 0 ||
          candidateX >= width ||
          candidateY < 0 ||
          candidateY >= height
        ) {
          continue;
        }

        const candidate = candidateY * width + candidateX;
        if (
          seedLabels[candidate] !== componentId ||
          selectedCoreMask[candidate] === 0
        ) {
          continue;
        }

        const distance = dx * dx + dy * dy;
        if (averageCandidates) {
          const weight = 1 / Math.max(1, distance);
          const offset = candidate * 4;
          weightedRed += data[offset] * weight;
          weightedGreen += data[offset + 1] * weight;
          weightedBlue += data[offset + 2] * weight;
          totalWeight += weight;
        }
        if (distance < bestDistance) {
          bestDistance = distance;
          bestPixel = candidate;
        }
      }
    }

    if (bestPixel !== -1) {
      if (averageCandidates && totalWeight > 0) {
        return [
          Math.round(weightedRed / totalWeight),
          Math.round(weightedGreen / totalWeight),
          Math.round(weightedBlue / totalWeight),
        ];
      }
      const offset = bestPixel * 4;
      return [data[offset], data[offset + 1], data[offset + 2]];
    }
  }

  return null;
};

const refineCleanMatte = (output, asset, selectedCoreMask) => {
  const bounds = asset.componentIds
    .map((componentId) => components[componentId])
    .reduce(
      (result, component) => ({
        minX: Math.min(result.minX, component.minX),
        maxX: Math.max(result.maxX, component.maxX),
        minY: Math.min(result.minY, component.minY),
        maxY: Math.max(result.maxY, component.maxY),
      }),
      { minX: width, maxX: 0, minY: height, maxY: 0 },
    );
  const minX = Math.max(1, bounds.minX - 5);
  const maxX = Math.min(width - 2, bounds.maxX + 5);
  const minY = Math.max(1, bounds.minY - 5);
  const maxY = Math.min(height - 2, bounds.maxY + 5);
  const originalAlpha = new Uint8Array(pixelCount);
  const medianAlpha = new Uint8Array(pixelCount);
  const horizontalAlpha = new Uint8Array(pixelCount);
  const blurredAlpha = new Uint8Array(pixelCount);

  for (let y = minY - 1; y <= maxY + 1; y++) {
    for (let x = minX - 1; x <= maxX + 1; x++) {
      const pixel = y * width + x;
      originalAlpha[pixel] = output.data[pixel * 4 + 3];
    }
  }

  for (let y = minY; y <= maxY; y++) {
    for (let x = minX; x <= maxX; x++) {
      const samples = [];
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          samples.push(originalAlpha[(y + dy) * width + x + dx]);
        }
      }
      samples.sort((left, right) => left - right);
      medianAlpha[y * width + x] = samples[4];
    }
  }

  for (let y = minY; y <= maxY; y++) {
    for (let x = minX; x <= maxX; x++) {
      const pixel = y * width + x;
      horizontalAlpha[pixel] = Math.round(
        (medianAlpha[pixel - 1] +
          2 * medianAlpha[pixel] +
          medianAlpha[pixel + 1]) /
          4,
      );
    }
  }

  for (let y = minY; y <= maxY; y++) {
    for (let x = minX; x <= maxX; x++) {
      const pixel = y * width + x;
      blurredAlpha[pixel] = Math.round(
        (horizontalAlpha[pixel - width] +
          2 * horizontalAlpha[pixel] +
          horizontalAlpha[pixel + width]) /
          4,
      );
    }
  }

  let visiblePixels = 0;
  let outputMinX = width;
  let outputMaxX = 0;
  let outputMinY = height;
  let outputMaxY = 0;

  for (let y = minY; y <= maxY; y++) {
    for (let x = minX; x <= maxX; x++) {
      const pixel = y * width + x;
      const offset = pixel * 4;
      const normalized = Math.max(
        0,
        Math.min(1, (blurredAlpha[pixel] - 10) / 235),
      );
      const smoothCoverage = normalized * normalized * (3 - 2 * normalized);
      const alpha = Math.round(smoothCoverage * 255);

      if (alpha <= cleanMatteAlphaFloor) {
        output.data[offset + 3] = 0;
        continue;
      }

      if (output.data[offset + 3] === 0) {
        const componentId = asset.componentIds.includes(assignedLabels[pixel])
          ? assignedLabels[pixel]
          : asset.componentIds[0];
        const coreColor = nearestCoreColor(
          pixel,
          componentId,
          selectedCoreMask,
          true,
        );
        if (coreColor === null) {
          output.data[offset + 3] = 0;
          continue;
        }
        output.data[offset] = coreColor[0];
        output.data[offset + 1] = coreColor[1];
        output.data[offset + 2] = coreColor[2];
      }

      output.data[offset + 3] = alpha;
      visiblePixels++;
      outputMinX = Math.min(outputMinX, x);
      outputMaxX = Math.max(outputMaxX, x);
      outputMinY = Math.min(outputMinY, y);
      outputMaxY = Math.max(outputMaxY, y);
    }
  }

  return {
    visiblePixels,
    minX: outputMinX,
    maxX: outputMaxX,
    minY: outputMinY,
    maxY: outputMaxY,
  };
};

fs.mkdirSync(outputDirectory, { recursive: true });

let canonicalTopHeadAlpha = null;

const preserveOpaqueDetails = (output, assetName) => {
  const eyeCenters = {
    "orbit-head-top": [
      [329, 405],
      [368, 405],
    ],
    "orbit-head-left": [
      [195, 602],
      [234, 602],
    ],
    "orbit-head-right": [
      [461, 601],
      [500, 601],
    ],
  }[assetName];

  if (!eyeCenters) {
    return;
  }

  for (const [centerX, centerY] of eyeCenters) {
    for (let dy = -9; dy <= 9; dy++) {
      for (let dx = -9; dx <= 9; dx++) {
        if (dx * dx + dy * dy > 81) {
          continue;
        }

        const pixel = (centerY + dy) * width + centerX + dx;
        const offset = pixel * 4;
        output.data[offset] = data[offset];
        output.data[offset + 1] = data[offset + 1];
        output.data[offset + 2] = data[offset + 2];
        output.data[offset + 3] = 255;
      }
    }
  }
};

for (const asset of assetDefinitions) {
  const componentSet = new Set(asset.componentIds);
  const selectedCoreMask = asset.cleanMatte ? cleanMatteCoreMask : coreMask;
  const output = new PNG({ width, height, colorType: 6 });

  let visiblePixels = 0;
  let minX = width;
  let maxX = 0;
  let minY = height;
  let maxY = 0;

  for (let pixel = 0; pixel < pixelCount; pixel++) {
    const componentId = assignedLabels[pixel];
    const x = pixel % width;
    const y = Math.floor(pixel / width);
    if (
      !componentSet.has(componentId) ||
      distances[pixel] > fringeRadius ||
      signal[pixel] === 0 ||
      (asset.includePixel && !asset.includePixel(x, y))
    ) {
      continue;
    }

    const sourceOffset = pixel * 4;
    const sourceRed = data[sourceOffset];
    const sourceGreen = data[sourceOffset + 1];
    const sourceBlue = data[sourceOffset + 2];

    let red = sourceRed;
    let green = sourceGreen;
    let blue = sourceBlue;
    let alpha = 255;

    if (selectedCoreMask[pixel] === 0) {
      const coreColor = nearestCoreColor(
        pixel,
        componentId,
        selectedCoreMask,
        asset.cleanMatte,
      );
      if (coreColor === null) {
        continue;
      }
      [red, green, blue] = coreColor;

      let numerator = 0;
      let denominator = 0;
      for (const [sourceChannel, foregroundChannel] of [
        [sourceRed, red],
        [sourceGreen, green],
        [sourceBlue, blue],
      ]) {
        const foregroundDistance = 255 - foregroundChannel;
        if (foregroundDistance <= 3) {
          continue;
        }
        numerator += foregroundDistance * (255 - sourceChannel);
        denominator += foregroundDistance * foregroundDistance;
      }

      const coverage =
        denominator === 0
          ? signal[pixel] / coreThreshold
          : numerator / denominator;
      alpha = Math.round(Math.max(0, Math.min(1, coverage)) * 255);
    }

    if (asset.cleanMatte && alpha <= cleanMatteAlphaFloor) {
      continue;
    }

    if (alpha === 0) {
      continue;
    }

    output.data[sourceOffset] = red;
    output.data[sourceOffset + 1] = green;
    output.data[sourceOffset + 2] = blue;
    output.data[sourceOffset + 3] = alpha;

    visiblePixels++;
    minX = Math.min(minX, x);
    maxX = Math.max(maxX, x);
    minY = Math.min(minY, y);
    maxY = Math.max(maxY, y);
  }

  if (asset.cleanMatte) {
    ({ visiblePixels, minX, maxX, minY, maxY } = refineCleanMatte(
      output,
      asset,
      selectedCoreMask,
    ));
  }

  if (asset.cleanText) {
    for (let y = minY; y <= maxY; y++) {
      for (let x = minX; x <= maxX; x++) {
        const offset = (y * width + x) * 4;
        if (output.data[offset + 3] === 0) {
          continue;
        }
        output.data[offset] = cleanTextColor[0];
        output.data[offset + 1] = cleanTextColor[1];
        output.data[offset + 2] = cleanTextColor[2];
      }
    }
  }

  const translatedHeadCenter = translatedHeadCenters[asset.name];
  if (canonicalTopHeadAlpha && translatedHeadCenter) {
    const [centerX, centerY] = translatedHeadCenter;
    const componentId = asset.componentIds[0];

    for (let y = centerY - 80; y <= centerY + 80; y++) {
      for (let x = centerX - 80; x <= centerX + 80; x++) {
        const pixel = y * width + x;
        const offset = pixel * 4;
        const canonicalX = x - centerX + 349;
        const canonicalY = y - centerY + 401;
        const canonicalAlpha =
          canonicalTopHeadAlpha[canonicalY * width + canonicalX];

        if (canonicalAlpha === 0) {
          output.data[offset + 3] = 0;
          continue;
        }

        const localX = x - centerX;
        const localY = y - centerY;
        const hadSourceColor = output.data[offset + 3] !== 0;
        const isJunctionArea =
          (asset.name === "orbit-head-left" && localY > 28 && localX > 34) ||
          (asset.name === "orbit-head-right" && localY > 28 && localX < -34);

        if (output.data[offset + 3] === 0 || isJunctionArea) {
          // Sample a clean patch from the lower body of the same head. Sampling
          // toward the center can hit the dark face plate and create wedges in
          // the reconstructed tail/junction area.
          const sampleX = Math.round(centerX + localX * 0.35);
          const sampleY = Math.round(centerY + 45);
          const samplePixel = sampleY * width + sampleX;
          const coreColor = nearestCoreColor(samplePixel, componentId);

          if (coreColor) {
            output.data[offset] = coreColor[0];
            output.data[offset + 1] = coreColor[1];
            output.data[offset + 2] = coreColor[2];
          }
        }

        const isFaceRegion =
          Math.abs(localX) <= 48 && localY >= -31 && localY <= 32;
        if (!isFaceRegion) {
          const ellipseDistance = Math.sqrt(
            (localX / 72) ** 2 + (localY / 66) ** 2,
          );
          const edgeMix = Math.max(
            0,
            Math.min(1, (ellipseDistance - 0.52) / 0.18),
          );
          const isTail = localY > 28 && localX < -10;
          const cleanMix =
            !hadSourceColor || isJunctionArea || isTail ? 1 : edgeMix;
          const cleanColor = getCleanHeadColor(asset.name, localX, localY);

          output.data[offset] = mixChannel(
            output.data[offset],
            cleanColor[0],
            cleanMix,
          );
          output.data[offset + 1] = mixChannel(
            output.data[offset + 1],
            cleanColor[1],
            cleanMix,
          );
          output.data[offset + 2] = mixChannel(
            output.data[offset + 2],
            cleanColor[2],
            cleanMix,
          );
        }

        output.data[offset + 3] = canonicalAlpha;
      }
    }

    visiblePixels = 0;
    minX = width;
    maxX = 0;
    minY = height;
    maxY = 0;

    for (let pixel = 0; pixel < pixelCount; pixel++) {
      if (output.data[pixel * 4 + 3] === 0) {
        continue;
      }

      const x = pixel % width;
      const y = Math.floor(pixel / width);
      visiblePixels++;
      minX = Math.min(minX, x);
      maxX = Math.max(maxX, x);
      minY = Math.min(minY, y);
      maxY = Math.max(maxY, y);
    }
  }

  if (visiblePixels === 0) {
    throw new Error(`Asset ${asset.name} is empty`);
  }

  preserveOpaqueDetails(output, asset.name);

  if (asset.name === "orbit-head-top") {
    canonicalTopHeadAlpha = new Uint8Array(pixelCount);
    for (let pixel = 0; pixel < pixelCount; pixel++) {
      canonicalTopHeadAlpha[pixel] = output.data[pixel * 4 + 3];
    }
  }

  const destination = path.join(outputDirectory, `${asset.name}.png`);
  fs.writeFileSync(destination, PNG.sync.write(output));
  console.log(
    `${asset.name}: components=${asset.componentIds.join(",")} pixels=${visiblePixels} bbox=${minX},${minY}-${maxX},${maxY}`,
  );
}

const clamp = (value, minimum, maximum) =>
  Math.max(minimum, Math.min(maximum, value));

const interpolateColor = (left, middle, right, progress) => {
  const from = progress <= 0.5 ? left : middle;
  const to = progress <= 0.5 ? middle : right;
  const localProgress = progress <= 0.5 ? progress * 2 : (progress - 0.5) * 2;

  return from.map((channel, index) =>
    Math.round(channel + (to[index] - channel) * localProgress),
  );
};

const writeSyntheticRing = () => {
  const output = new PNG({ width, height, colorType: 6 });
  const centerX = 349;
  const centerY = 546;
  const radius = 136;
  const halfStroke = 5.5;
  const antialiasWidth = 1.5;
  const nodeRadius = 14;
  const nodeCenterY = centerY + radius;
  let visiblePixels = 0;
  let minX = width;
  let maxX = 0;
  let minY = height;
  let maxY = 0;

  for (
    let y = centerY - radius - nodeRadius;
    y <= nodeCenterY + nodeRadius;
    y++
  ) {
    for (
      let x = centerX - radius - nodeRadius;
      x <= centerX + radius + nodeRadius;
      x++
    ) {
      const ringDistance = Math.abs(
        Math.hypot(x - centerX, y - centerY) - radius,
      );
      const ringCoverage =
        clamp(halfStroke + antialiasWidth - ringDistance, 0, antialiasWidth) /
        antialiasWidth;
      const nodeDistance = Math.hypot(x - centerX, y - nodeCenterY);
      const nodeCoverage =
        clamp(nodeRadius + antialiasWidth - nodeDistance, 0, antialiasWidth) /
        antialiasWidth;
      const coverage = Math.max(ringCoverage, nodeCoverage);

      if (coverage === 0) {
        continue;
      }

      const progress = clamp((x - (centerX - radius)) / (radius * 2), 0, 1);
      const [red, green, blue] = interpolateColor(
        [76, 119, 255],
        [139, 70, 246],
        [244, 78, 216],
        progress,
      );
      const offset = (y * width + x) * 4;
      output.data[offset] = red;
      output.data[offset + 1] = green;
      output.data[offset + 2] = blue;
      output.data[offset + 3] = Math.round(coverage * 255);

      visiblePixels++;
      minX = Math.min(minX, x);
      maxX = Math.max(maxX, x);
      minY = Math.min(minY, y);
      maxY = Math.max(maxY, y);
    }
  }

  fs.writeFileSync(
    path.join(outputDirectory, "orbit-ring.png"),
    PNG.sync.write(output),
  );
  console.log(
    `orbit-ring: synthetic pixels=${visiblePixels} bbox=${minX},${minY}-${maxX},${maxY}`,
  );
};

writeSyntheticRing();
