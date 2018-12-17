from tools.kaldi.tools.nara_wpe.nara_wpe.wpe import wpe


class WPE(object):
    def __init__(self, taps=10, delay=3, iterations=3, psd_context=0,
                 statistics_mode='full'):
        self.taps = taps
        self.delay = delay
        self.iterations = iterations
        self.psd_context = psd_context
        self.statistics_mode = statistics_mode

    def __repr__(self):
        return ('{name}(taps={taps}, delay={delay}'
                'iterations={iterations}, psd_context={psd_context}, '
                'statistics_mode={statistics_mode})'
                .format(name=self.__class__.__name__,
                        taps=self.taps,
                        delay=self.delay,
                        iterations=self.iterations,
                        psd_context=self.psd_context,
                        statistics_mode=self.statistics_mode))

    def __call__(self, xs):
        """

        :param np.ndarray xs: (Channel, Time, Frequency)
        :return: enhanced_xs
        :return type: np.ndarray

        """
        xs = wpe(xs.transpose((2, 0, 1)),
                 taps=self.taps,
                 delay=self.delay,
                 iterations=self.iterations,
                 psd_context=self.psd_context,
                 statistics_mode=self.statistics_mode)
        return xs.transpose(1, 2, 0)
