import {
  AbsoluteFill,
  CanvasImage,
  Composition,
  Easing,
  Interactive,
  interpolate,
  Sequence,
  staticFile,
  useCurrentFrame,
} from "remotion";

const SOURCE_SIZE = 1254;

type LayerImageProps = {
  asset: string;
};

const LayerImage: React.FC<LayerImageProps> = ({ asset }) => {
  return (
    <CanvasImage
      src={staticFile(`layers/${asset}.png`)}
      width={SOURCE_SIZE}
      height={SOURCE_SIZE}
      fit="fill"
      showInTimeline={false}
      style={{
        position: "absolute",
        inset: 0,
        width: SOURCE_SIZE,
        height: SOURCE_SIZE,
      }}
    />
  );
};

const HandLayer: React.FC = () => {
  const frame = useCurrentFrame();

  return (
    <Interactive.Div
      name="Hand — slide, reveal and settle"
      style={{
        position: "absolute",
        inset: 0,
        width: SOURCE_SIZE,
        height: SOURCE_SIZE,
        opacity: interpolate(frame, [0, 28], [0, 1], {
          easing: Easing.bezier(0.16, 1, 0.3, 1),
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        translate: interpolate(
          frame,
          [0, 58, 188],
          ["-285px 110px", "0px 0px", "0px -2px"],
          {
            easing: [Easing.bezier(0.16, 1, 0.3, 1), Easing.linear],
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          },
        ),
        scale: interpolate(frame, [0, 58], [0.82, 1], {
          easing: Easing.bezier(0.16, 1, 0.3, 1),
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
          output: "perceptual-scale",
        }),
        rotate: interpolate(
          frame,
          [0, 52, 82, 112, 142, 170],
          ["-12deg", "3deg", "-1.8deg", "1deg", "-0.45deg", "0deg"],
          {
            easing: [
              Easing.bezier(0.16, 1, 0.3, 1),
              Easing.bezier(0.45, 0, 0.55, 1),
              Easing.bezier(0.45, 0, 0.55, 1),
              Easing.bezier(0.45, 0, 0.55, 1),
              Easing.bezier(0.16, 1, 0.3, 1),
            ],
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          },
        ),
        transformOrigin: "152px 766px",
      }}
    >
      <LayerImage asset="hand" />
    </Interactive.Div>
  );
};

const OrbitingHeads: React.FC = () => {
  const frame = useCurrentFrame();

  return (
    <Interactive.Div
      name="Three heads — orbit around the fixed ring"
      style={{
        position: "absolute",
        inset: 0,
        width: SOURCE_SIZE,
        height: SOURCE_SIZE,
        rotate: interpolate(
          frame,
          [12, 117, 150],
          ["-12deg", "342deg", "360deg"],
          {
            easing: [Easing.linear, Easing.bezier(0.12, 0.72, 0.2, 1)],
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          },
        ),
        transformOrigin: "349px 546px",
      }}
    >
      <Interactive.Div
        name="Top purple head — stays upright"
        style={{
          position: "absolute",
          inset: 0,
          width: SOURCE_SIZE,
          height: SOURCE_SIZE,
          rotate: interpolate(
            frame,
            [12, 117, 150],
            ["12deg", "-342deg", "-360deg"],
            {
              easing: [Easing.linear, Easing.bezier(0.12, 0.72, 0.2, 1)],
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            },
          ),
          transformOrigin: "349px 401px",
        }}
      >
        <LayerImage asset="orbit-head-top" />
      </Interactive.Div>
      <Interactive.Div
        name="Left blue head — stays upright"
        style={{
          position: "absolute",
          inset: 0,
          width: SOURCE_SIZE,
          height: SOURCE_SIZE,
          rotate: interpolate(
            frame,
            [12, 117, 150],
            ["12deg", "-342deg", "-360deg"],
            {
              easing: [Easing.linear, Easing.bezier(0.12, 0.72, 0.2, 1)],
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            },
          ),
          transformOrigin: "211px 594px",
        }}
      >
        <LayerImage asset="orbit-head-left" />
      </Interactive.Div>
      <Interactive.Div
        name="Right pink head — stays upright"
        style={{
          position: "absolute",
          inset: 0,
          width: SOURCE_SIZE,
          height: SOURCE_SIZE,
          rotate: interpolate(
            frame,
            [12, 117, 150],
            ["12deg", "-342deg", "-360deg"],
            {
              easing: [Easing.linear, Easing.bezier(0.12, 0.72, 0.2, 1)],
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            },
          ),
          transformOrigin: "481px 594px",
        }}
      >
        <LayerImage asset="orbit-head-right" />
      </Interactive.Div>
    </Interactive.Div>
  );
};

const EmblemLayer: React.FC = () => {
  const frame = useCurrentFrame();

  return (
    <Interactive.Div
      name="Raised emblem — reveal and settle"
      style={{
        position: "absolute",
        inset: 0,
        width: SOURCE_SIZE,
        height: SOURCE_SIZE,
        opacity: interpolate(frame, [0, 54], [0, 1], {
          easing: Easing.bezier(0.4, 0, 0.2, 1),
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        translate: interpolate(
          frame,
          [12, 38, 52, 82, 112, 142, 170, 188],
          [
            "0px -66px",
            "0px -92px",
            "0px -83px",
            "0px -97px",
            "0px -86px",
            "0px -94px",
            "0px -92px",
            "0px -94px",
          ],
          {
            easing: [
              Easing.bezier(0.16, 1, 0.3, 1),
              Easing.bezier(0.45, 0, 0.55, 1),
              Easing.bezier(0.45, 0, 0.55, 1),
              Easing.bezier(0.45, 0, 0.55, 1),
              Easing.bezier(0.45, 0, 0.55, 1),
              Easing.bezier(0.16, 1, 0.3, 1),
              Easing.linear,
            ],
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          },
        ),
        scale: interpolate(frame, [0, 54], [0.92, 1], {
          easing: Easing.bezier(0.4, 0, 0.2, 1),
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
          output: "perceptual-scale",
        }),
        transformOrigin: "349px 546px",
      }}
    >
      <Interactive.Div
        name="Ring — fixed in place"
        style={{
          position: "absolute",
          inset: 0,
          width: SOURCE_SIZE,
          height: SOURCE_SIZE,
        }}
      >
        <LayerImage asset="orbit-ring" />
      </Interactive.Div>
      <Interactive.Div
        name="Center star — gentle pulse"
        style={{
          position: "absolute",
          inset: 0,
          width: SOURCE_SIZE,
          height: SOURCE_SIZE,
          scale: interpolate(
            frame,
            [12, 38, 72, 106, 140, 174],
            [0.78, 1, 1.055, 0.96, 1.04, 1],
            {
              easing: [
                Easing.bezier(0.16, 1, 0.3, 1),
                Easing.bezier(0.45, 0, 0.55, 1),
                Easing.bezier(0.45, 0, 0.55, 1),
                Easing.bezier(0.45, 0, 0.55, 1),
                Easing.bezier(0.16, 1, 0.3, 1),
              ],
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              output: "perceptual-scale",
            },
          ),
          transformOrigin: "350px 548px",
        }}
      >
        <LayerImage asset="orbit-star" />
      </Interactive.Div>
      <OrbitingHeads />
    </Interactive.Div>
  );
};

type LetterLayerProps = {
  name: string;
  asset: string;
};

const LetterLayer: React.FC<LetterLayerProps> = ({ name, asset }) => {
  const frame = useCurrentFrame();

  return (
    <Interactive.Div
      name={`Letter ${name}`}
      style={{
        position: "absolute",
        inset: 0,
        width: SOURCE_SIZE,
        height: SOURCE_SIZE,
        opacity: interpolate(frame, [0, 16], [0, 1], {
          easing: Easing.bezier(0.16, 1, 0.3, 1),
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        translate: interpolate(frame, [0, 18], ["20px 0px", "0px 0px"], {
          easing: Easing.bezier(0.16, 1, 0.3, 1),
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
      }}
    >
      <LayerImage asset={asset} />
    </Interactive.Div>
  );
};

const DotLayer: React.FC = () => {
  const frame = useCurrentFrame();

  return (
    <Interactive.Div
      name="Purple i dot — reveal and bounce"
      style={{
        position: "absolute",
        inset: 0,
        width: SOURCE_SIZE,
        height: SOURCE_SIZE,
        opacity: interpolate(frame, [59, 75], [0, 1], {
          easing: Easing.bezier(0.16, 1, 0.3, 1),
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        translate: interpolate(
          frame,
          [59, 75, 125, 139, 154, 166],
          ["20px 0px", "0px 0px", "0px 0px", "0px -42px", "0px 7px", "0px 0px"],
          {
            easing: [
              Easing.bezier(0.16, 1, 0.3, 1),
              Easing.linear,
              Easing.bezier(0.2, 0.9, 0.25, 1),
              Easing.bezier(0.34, 1.56, 0.64, 1),
              Easing.bezier(0.16, 1, 0.3, 1),
            ],
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          },
        ),
        scale: interpolate(frame, [125, 139, 154, 166], [1, 1.12, 0.96, 1], {
          easing: [
            Easing.bezier(0.2, 0.9, 0.25, 1),
            Easing.bezier(0.34, 1.56, 0.64, 1),
            Easing.bezier(0.16, 1, 0.3, 1),
          ],
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
          output: "perceptual-scale",
        }),
        transformOrigin: "903px 461px",
      }}
    >
      <LayerImage asset="i-dot" />
    </Interactive.Div>
  );
};

type AnimationProps = {
  debugBackground: boolean;
  darkBackground?: boolean;
};

export const ThirdHandLogoAnimation: React.FC<AnimationProps> = ({
  debugBackground,
  darkBackground = false,
}) => {
  return (
    <AbsoluteFill
      name="Third Hand logo animation"
      style={{
        backgroundColor: darkBackground
          ? "#05070d"
          : debugBackground
            ? "#728197"
            : "transparent",
        backgroundImage:
          debugBackground && !darkBackground
            ? "linear-gradient(45deg, #55657c 25%, transparent 25%), linear-gradient(-45deg, #55657c 25%, transparent 25%), linear-gradient(45deg, transparent 75%, #55657c 75%), linear-gradient(-45deg, transparent 75%, #55657c 75%)"
            : undefined,
        backgroundPosition:
          debugBackground && !darkBackground
            ? "0 0, 0 32px, 32px -32px, -32px 0px"
            : undefined,
        backgroundSize:
          debugBackground && !darkBackground ? "64px 64px" : undefined,
        overflow: "hidden",
      }}
    >
      <HandLayer />
      <EmblemLayer />

      <Sequence name="Third — T" from={45} layout="none">
        <LetterLayer name="T" asset="third-t" />
      </Sequence>
      <Sequence name="Third — h" from={52} layout="none">
        <LetterLayer name="h" asset="third-h" />
      </Sequence>
      <Sequence name="Third — i stem" from={59} layout="none">
        <LetterLayer name="i stem" asset="third-i-stem" />
      </Sequence>
      <Sequence name="Third — r" from={66} layout="none">
        <LetterLayer name="r" asset="third-r" />
      </Sequence>
      <Sequence name="Third — d" from={73} layout="none">
        <LetterLayer name="d" asset="third-d" />
      </Sequence>

      <Sequence name="Hand — H" from={80} layout="none">
        <LetterLayer name="H" asset="hand-h" />
      </Sequence>
      <Sequence name="Hand — a" from={87} layout="none">
        <LetterLayer name="a" asset="hand-a" />
      </Sequence>
      <Sequence name="Hand — n" from={94} layout="none">
        <LetterLayer name="n" asset="hand-n" />
      </Sequence>
      <Sequence name="Hand — d" from={101} layout="none">
        <LetterLayer name="d" asset="hand-d" />
      </Sequence>

      <DotLayer />
    </AbsoluteFill>
  );
};

export const RemotionComposition: React.FC = () => {
  return (
    <>
      <Composition
        id="ThirdHandLogo"
        component={ThirdHandLogoAnimation}
        durationInFrames={210}
        fps={30}
        width={1254}
        height={1254}
        defaultProps={{
          debugBackground: false,
        }}
      />
      <Composition
        id="ThirdHandLogoDebug"
        component={ThirdHandLogoAnimation}
        durationInFrames={210}
        fps={30}
        width={1254}
        height={1254}
        defaultProps={{
          debugBackground: true,
        }}
      />
      <Composition
        id="ThirdHandLogoDark"
        component={ThirdHandLogoAnimation}
        durationInFrames={210}
        fps={30}
        width={1254}
        height={1254}
        defaultProps={{
          debugBackground: false,
          darkBackground: true,
        }}
      />
    </>
  );
};
